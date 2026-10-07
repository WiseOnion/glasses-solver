import Foundation
import MWDATCamera
import MWDATCore
import UIKit

enum GlassesError: LocalizedError {
  case noGlasses
  case sessionEnded(String?)
  case cameraUnavailable
  case captureRejected
  case sessionPaused
  /// The camera stream reported an error (kept typed for the log).
  case stream(StreamError)
  case camera(String)
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .noGlasses:
      return "No glasses found. Put them on, open the hinges, and make sure they're connected in the Meta AI app."
    case .sessionEnded(let reason):
      return "The glasses connection ended" + (reason.map { ": \($0)" } ?? ".")
    case .cameraUnavailable:
      return "Couldn't start the glasses camera. Try again."
    case .captureRejected:
      return "The glasses are busy with another capture. Try again in a moment."
    case .sessionPaused:
      return "The glasses session is paused. Tap the touchpad once to resume it."
    case .stream:
      return "The glasses camera didn't start."
    case .camera(let message):
      return message
    case .timedOut(let step):
      return "Timed out \(step)."
    }
  }

  /// Failures a fresh glasses session can fix. In SDK 1.0.0, restarting a camera stream in a
  /// session that has already streamed can fail at once with `StreamError.internalError`
  /// (Meta, SDK issue #260), while the first stream in a new session works.
  var isFixedByFreshSession: Bool {
    switch self {
    case .stream, .camera, .cameraUnavailable, .captureRejected, .sessionEnded, .timedOut: true
    case .noGlasses, .sessionPaused: false
    }
  }
}

/// Takes one photo from the glasses: starts (or reuses) a DeviceSession, attaches the
/// camera, captures, then detaches the camera so the next capture starts clean.
/// The hands-free session shares this DeviceSession, since only one can run at a time.
@MainActor
final class GlassesCamera {
  private let wearables: any WearablesInterface
  private let selector: AutoDeviceSelector
  private var session: DeviceSession?
  private let sessionTokens = ListenerTokenBag()
  private let lastSessionError = LockedValue<String?>(nil)
  private var lastSessionStop: ContinuousClock.Instant?
  private var activeCamera: Camera?

  /// Meta's workaround for glasses that get stuck refusing sessions (SDK issue #231):
  /// leave at least this long between stopping one session and starting the next.
  private static let sessionRestartGap = Duration.seconds(2)

  init(wearables: any WearablesInterface, selector: AutoDeviceSelector) {
    self.wearables = wearables
    self.selector = selector
  }

  /// The current session, if one has been created and not ended.
  var currentSession: DeviceSession? { session }

  /// Stops a capture in progress. Used when iOS is about to suspend the app: a stream left
  /// running through a suspension can leave the glasses refusing sessions (SDK issue #231).
  func abortCapture() {
    guard let activeCamera else { return }
    diag("camera", "aborting capture (app about to be suspended)")
    activeCamera.stop()
  }

  /// Returns the photo's encoded bytes (JPEG, or HEIC for the high-res path).
  /// With `keepSession`, a session that isn't running is reported as paused instead of
  /// being replaced, so a hands-free session is never torn down by a capture.
  func capturePhoto(highResolution: Bool, keepSession: Bool = false) async throws -> Data {
    if keepSession, let existing = self.session, existing.state != .started {
      diag("camera", "session is \(existing.state); not replacing the hands-free session")
      throw GlassesError.sessionPaused
    }
    let session = try await startedSession()

    // The SDK pauses a `.raw` stream while the app is in the background and keeps an
    // `.hvc1` one flowing (SDK changelog, 0.5.0). Raw stays the foreground default
    // because it's the path this app was first tested on.
    let inBackground = UIApplication.shared.applicationState != .active
    let config: StreamConfiguration
    if highResolution {
      // This stream only wakes the camera for the standalone photo; keep it small.
      config = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 7)
    } else {
      config = StreamConfiguration(videoCodec: inBackground ? .hvc1 : .raw, resolution: .high, frameRate: 15)
    }
    diag(
      "camera",
      "addCamera (highRes \(highResolution), background \(inBackground), "
        + "codec \(highResolution || inBackground ? "hvc1" : "raw"))")
    guard let camera = try session.addCamera(config: config) else {
      diag("camera", "addCamera returned nil (session state \(session.state))")
      throw GlassesError.cameraUnavailable
    }
    activeCamera = camera
    defer {
      camera.stop()
      activeCamera = nil
    }

    let startedAt = ContinuousClock.now
    do {
      let data: Data
      if highResolution {
        data = try await Self.standalonePhoto(camera)
      } else {
        data = try await Self.streamPhoto(camera.stream)
      }
      diag("camera", "photo: \(data.count) bytes in \(ContinuousClock.now - startedAt)")
      return data
    } catch {
      diag(
        "camera",
        "photo FAILED after \(ContinuousClock.now - startedAt): \(ErrorDetail.describe(error)) "
          + "(stream \(camera.stream.state), camera \(camera.state))")
      throw error
    }
  }

  // MARK: - Session

  /// Ends the current session and starts a new one (waiting out the restart gap). In SDK
  /// 1.0.0 only the first camera stream in a session is reliable, so a session is used for
  /// one photo and then refreshed.
  func refreshSession() async throws -> DeviceSession {
    endSession()
    return try await startedSession()
  }

  /// Ends the current session, if any. The next capture starts a new one.
  func endSession() {
    diag("session", "endSession() (state was \(session.map { "\($0.state)" } ?? "none"))")
    if session != nil { lastSessionStop = .now }
    session?.stop()
    session = nil
    sessionTokens.clear()
  }

  func startedSession() async throws -> DeviceSession {
    logDeviceSnapshot()
    guard selector.activeDevice != nil else {
      diag("session", "no active device; not creating a session")
      throw GlassesError.noGlasses
    }
    if let existing = session {
      if existing.state == .started {
        diag("session", "reusing started session")
        return existing
      }
      // Paused, stopping, or stopped: end it and start fresh.
      diag("session", "existing session is \(existing.state); stopping it first")
      existing.stop()
      do {
        try await withTimeout(seconds: 5, timeoutError: GlassesError.timedOut("closing the old session")) {
          for await _ in existing.stateStream() {}
        }
      } catch {
        diag("session", "old session didn't finish stopping: \(ErrorDetail.describe(error))")
      }
      sessionTokens.clear()
      session = nil
      lastSessionStop = .now
    }

    if let lastSessionStop {
      let wait = Self.sessionRestartGap - (ContinuousClock.now - lastSessionStop)
      if wait > .zero {
        diag("session", "waiting \(wait) before starting a new session")
        try await Task.sleep(for: wait)
      }
    }

    let newSession: DeviceSession
    do {
      newSession = try wearables.createSession(deviceSelector: selector)
      diag("session", "createSession OK (device \(newSession.deviceId))")
    } catch {
      diag("session", "createSession FAILED: \(ErrorDetail.describe(error))")
      throw error
    }
    session = newSession
    lastSessionError.set(nil)
    let lastError = lastSessionError
    newSession.errorPublisher.listen { error in
      let detail = ErrorDetail.describe(error)
      diag("session", "session error: \(detail)")
      lastError.set(detail)
    }.store(in: sessionTokens)

    // Subscribe before start() so no transition is missed.
    let states = newSession.stateStream()
    do {
      try newSession.start()
      diag("session", "start() returned; waiting for .started")
    } catch {
      diag("session", "start() FAILED: \(ErrorDetail.describe(error))")
      session = nil
      sessionTokens.clear()
      throw error
    }

    let startedAt = ContinuousClock.now
    let reached: Bool
    do {
      reached = try await withTimeout(
        seconds: 20, timeoutError: GlassesError.timedOut("connecting to the glasses")
      ) {
        for await state in states {
          diag("session", "state -> \(state) after \(ContinuousClock.now - startedAt)")
          if state == .started { return true }
          if state == .stopped { return false }
        }
        diag("session", "state stream finished without .started")
        return false
      }
    } catch {
      diag("session", "waiting for .started FAILED: \(ErrorDetail.describe(error)) (state \(newSession.state))")
      throw error
    }
    guard reached else {
      session = nil
      sessionTokens.clear()
      throw GlassesError.sessionEnded(lastSessionError.get())
    }
    return newSession
  }

  /// Logs what the SDK reports about the glasses right now.
  private func logDeviceSnapshot() {
    let ids = wearables.devices
    let active = selector.activeDevice ?? "none"
    var line = "registration \(wearables.registrationState), devices \(ids.count), active \(active)"
    for id in ids {
      guard let device = wearables.deviceForIdentifier(id) else {
        line += "; \(id): no details"
        continue
      }
      line += "; \(device.nameOrId()): type \(device.deviceType().rawValue), link \(device.linkState), "
        + "compatibility \(device.compatibility()), hinges \(device.hingeState), worn \(device.donState), "
        + "battery \(device.batteryLevel.map { "\($0)%" } ?? "?")"
    }
    diag("device", line)
  }

  // MARK: - Capture paths

  /// Stable path: start the video stream, give auto-exposure a moment, then take a
  /// still with `Stream.capturePhoto(format:)`.
  nonisolated private static func streamPhoto(_ stream: MWDATCamera.Stream) async throws -> Data {
    let tokens = ListenerTokenBag()
    defer { tokens.clear() }
    let shot = OneShot<Data>()

    return try await withTimeout(seconds: 30, timeoutError: GlassesError.timedOut("taking the photo")) {
      try await shot.wait {
        stream.photoDataPublisher.listen { photo in
          shot.succeed(photo.data)
        }.store(in: tokens)
        stream.errorPublisher.listen { error in
          diag("camera", "stream error: \(ErrorDetail.describe(error))")
          shot.fail(GlassesError.stream(error))
        }.store(in: tokens)
        stream.statePublisher.listen { state in
          switch state {
          case .streaming:
            guard shot.claimTrigger() else { return }
            Task {
              try? await Task.sleep(for: .seconds(1))
              if !stream.capturePhoto(format: .jpeg) {
                shot.fail(GlassesError.captureRejected)
              }
            }
          case .starting, .waitingForDevice, .paused:
            shot.markActive()
          case .stopped:
            if shot.wasActive {
              shot.fail(GlassesError.camera("The glasses camera stopped before the photo was taken."))
            }
          case .stopping:
            break
          }
        }.store(in: tokens)
        stream.start()
      }
    }
  }

  /// Experimental path (SDK 1.0 `Camera.photo`): a standalone high-quality still,
  /// transferred from the glasses. Slower, but much sharper for small print.
  ///
  /// Meta's BirdSpotter sample notes that `Photo.start()` on a cold camera can sit at
  /// `starting`, so a small video stream wakes the sensor first. Stream and Photo compete
  /// for the camera, so the stream is stopped before the still is taken.
  nonisolated private static func standalonePhoto(_ camera: Camera) async throws -> Data {
    let stream = camera.stream
    let photo = camera.photo
    let tokens = ListenerTokenBag()
    defer {
      tokens.clear()
      photo.stop()
    }
    let shot = OneShot<Data>()
    let photoStartRequested = LockedValue(false)

    return try await withTimeout(seconds: 60, timeoutError: GlassesError.timedOut("transferring the photo")) {
      try await shot.wait {
        photo.photoDataPublisher.listen { capture in
          shot.succeed(capture.imageData)
        }.store(in: tokens)
        photo.errorPublisher.listen { error in
          shot.fail(GlassesError.camera(error.localizedDescription))
        }.store(in: tokens)
        photo.transferProgressPublisher.listen { progress in
          diag("camera", "photo transfer \(Int(progress.fraction * 100))%")
        }.store(in: tokens)
        photo.statePublisher.listen { state in
          diag("camera", "photo state -> \(state)")
          switch state {
          case .started:
            guard shot.claimTrigger() else { return }
            stream.stop()
            Task {
              // A still taken while the stream still holds the sensor is refused.
              let deadline = ContinuousClock.now + .seconds(2)
              while stream.state != .stopped, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
              }
              photo.capturePhoto(resolution: .large, quality: .high)
            }
          case .starting:
            shot.markActive()
          case .stopped:
            if shot.wasActive {
              shot.fail(GlassesError.camera("The glasses camera stopped before the photo arrived."))
            }
          case .stopping:
            break
          @unknown default:
            break
          }
        }.store(in: tokens)
        stream.statePublisher.listen { state in
          diag("camera", "wake stream state -> \(state)")
          guard state == .streaming, !photoStartRequested.get() else { return }
          photoStartRequested.set(true)
          photo.start()
        }.store(in: tokens)
        stream.start()
      }
    }
  }
}

// MARK: - Concurrency helpers

/// Bridges the SDK's listener callbacks to async/await: resolves exactly once, from
/// whichever callback (or cancellation) gets there first.
final class OneShot<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var result: Result<Value, Error>?
  private var triggered = false
  private var active = false

  var wasActive: Bool { lock.withLock { active } }

  func markActive() { lock.withLock { active = true } }

  /// True the first time only, so a repeated state callback can't capture twice.
  func claimTrigger() -> Bool {
    lock.withLock {
      active = true
      if triggered { return false }
      triggered = true
      return true
    }
  }

  func wait(start: () -> Void) async throws -> Value {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
        let earlyResult: Result<Value, Error>? = lock.withLock {
          if let result { return result }
          self.continuation = continuation
          return nil
        }
        if let earlyResult {
          continuation.resume(with: earlyResult)
        } else {
          start()
        }
      }
    } onCancel: {
      fail(CancellationError())
    }
  }

  func succeed(_ value: Value) { finish(.success(value)) }
  func fail(_ error: Error) { finish(.failure(error)) }

  private func finish(_ newResult: Result<Value, Error>) {
    let waiting: CheckedContinuation<Value, Error>? = lock.withLock {
      guard result == nil else { return nil }
      result = newResult
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume(with: newResult)
  }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func get() -> Value { lock.withLock { value } }
  func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

/// Runs `operation`, throwing `timeoutError` if it doesn't finish in time.
func withTimeout<T: Sendable>(
  seconds: Double,
  timeoutError: @autoclosure @escaping @Sendable () -> Error,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw timeoutError()
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw CancellationError() }
    return result
  }
}
