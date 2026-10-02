import Foundation
import MWDATCamera
import MWDATCore

enum GlassesError: LocalizedError {
  case noGlasses
  case sessionEnded(String?)
  case cameraUnavailable
  case captureRejected
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
    case .camera(let message):
      return message
    case .timedOut(let step):
      return "Timed out \(step)."
    }
  }
}

/// Takes one photo from the glasses: starts (or reuses) a DeviceSession, attaches the
/// camera, captures, then detaches the camera so the next capture starts clean.
@MainActor
final class GlassesCamera {
  private let wearables: any WearablesInterface
  private let selector: AutoDeviceSelector
  private var session: DeviceSession?
  private let sessionTokens = ListenerTokenBag()
  private let lastSessionError = LockedValue<String?>(nil)

  init(wearables: any WearablesInterface, selector: AutoDeviceSelector) {
    self.wearables = wearables
    self.selector = selector
  }

  /// Returns the photo's encoded bytes (JPEG, or HEIC for the high-res path).
  func capturePhoto(highResolution: Bool) async throws -> Data {
    guard selector.activeDevice != nil else { throw GlassesError.noGlasses }
    let session = try await startedSession()

    let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 15)
    guard let camera = try session.addCamera(config: config) else {
      throw GlassesError.cameraUnavailable
    }
    defer { camera.stop() }

    if highResolution {
      return try await Self.standalonePhoto(camera.photo)
    } else {
      return try await Self.streamPhoto(camera.stream)
    }
  }

  // MARK: - Session

  private func startedSession() async throws -> DeviceSession {
    if let existing = session {
      if existing.state == .started { return existing }
      // Paused, stopping, or stopped: end it and start fresh.
      existing.stop()
      try? await withTimeout(seconds: 5, timeoutError: GlassesError.timedOut("closing the old session")) {
        for await _ in existing.stateStream() {}
      }
      sessionTokens.clear()
      session = nil
    }

    let newSession = try wearables.createSession(deviceSelector: selector)
    session = newSession
    lastSessionError.set(nil)
    let lastError = lastSessionError
    newSession.errorPublisher.listen { error in
      lastError.set(error.localizedDescription)
    }.store(in: sessionTokens)

    // Subscribe before start() so no transition is missed.
    let states = newSession.stateStream()
    try newSession.start()

    let reached = try await withTimeout(
      seconds: 20, timeoutError: GlassesError.timedOut("connecting to the glasses")
    ) {
      for await state in states {
        if state == .started { return true }
        if state == .stopped { return false }
      }
      return false
    }
    guard reached else {
      session = nil
      sessionTokens.clear()
      throw GlassesError.sessionEnded(lastSessionError.get())
    }
    return newSession
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
          shot.fail(GlassesError.camera(error.localizedDescription))
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
  nonisolated private static func standalonePhoto(_ photo: MWDATCamera.Photo) async throws -> Data {
    let tokens = ListenerTokenBag()
    defer {
      tokens.clear()
      photo.stop()
    }
    let shot = OneShot<Data>()

    return try await withTimeout(seconds: 60, timeoutError: GlassesError.timedOut("transferring the photo")) {
      try await shot.wait {
        photo.photoDataPublisher.listen { capture in
          shot.succeed(capture.imageData)
        }.store(in: tokens)
        photo.errorPublisher.listen { error in
          shot.fail(GlassesError.camera(error.localizedDescription))
        }.store(in: tokens)
        photo.statePublisher.listen { state in
          switch state {
          case .started:
            guard shot.claimTrigger() else { return }
            photo.capturePhoto(resolution: .large, quality: .high)
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
        photo.start()
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
