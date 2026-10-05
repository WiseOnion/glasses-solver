import Foundation
import MWDATCore
import Observation
import UIKit

@Observable
@MainActor
final class AppModel {
  enum Phase: Equatable {
    case idle
    case capturing
    case thinking
  }

  private static let apiKeyAccount = "anthropic-api-key"
  private static let highResDefaultsKey = "useHighResPhoto"

  private(set) var registrationState: RegistrationState
  private(set) var hasActiveDevice = false
  private(set) var phase: Phase = .idle
  private(set) var lastPhoto: UIImage?
  private(set) var lastAnswer = ""
  private(set) var hasAPIKey: Bool

  // Hands-free session (capture button on the glasses)
  private(set) var sessionActive = false
  private(set) var isStartingSession = false
  private(set) var sessionPaused = false
  private(set) var sessionPrompt = ClaudeClient.defaultPrompt
  private(set) var shutterStatus: ShutterButton.Status = .off

  var errorMessage: String?
  var showCameraPermissionPrompt = false
  var useHighResPhoto: Bool {
    didSet { UserDefaults.standard.set(useHighResPhoto, forKey: Self.highResDefaultsKey) }
  }

  var isBusy: Bool { phase != .idle }
  var isRegistered: Bool { registrationState == .registered }

  var statusText: String {
    switch phase {
    case .capturing: return "Taking a photo with your glasses…"
    case .thinking: return "Claude is solving it…"
    case .idle:
      if sessionActive {
        return sessionPaused
          ? "Session paused. Tap the glasses' touchpad once to resume."
          : "Session active. Look at the problem and press the capture button."
      }
      if !hasAPIKey { return "Add your Anthropic API key in Settings." }
      if !isRegistered { return "Connect your glasses to get started." }
      if !hasActiveDevice { return "Put on your glasses (hinges open)." }
      return "Ready. Look at the problem and tap Solve."
    }
  }

  @ObservationIgnored private let wearables: any WearablesInterface
  @ObservationIgnored private let selector: AutoDeviceSelector
  @ObservationIgnored private let camera: GlassesCamera
  @ObservationIgnored private let speaker = Speaker()
  @ObservationIgnored private let shutter = ShutterButton()
  @ObservationIgnored private var sessionStateTask: Task<Void, Never>?
  @ObservationIgnored private var pendingSessionPrompt: String?
  @ObservationIgnored private var shutterReviveTask: Task<Void, Never>?
  @ObservationIgnored private var shutterAttempts = 0
  @ObservationIgnored private var shutterProblemReported = false
  /// Attempts to (re)attach button events before telling the wearer they're unavailable.
  private static let maxShutterAttempts = 4
  /// Presses closer together than this (by the glasses' clock) count as one. Covers a
  /// burst delivered at once when the app wakes, and a fast double press that may arrive
  /// as two short presses.
  private static let pressDebounceMs: Int64 = 800
  @ObservationIgnored private var lastPressTimestampMs: Int64?
  /// Smallest (phone clock − glasses clock) seen, i.e. the fastest delivery so far. A press
  /// whose offset is well above it waited somewhere, likely while iOS had the app suspended.
  @ObservationIgnored private var pressOffsetBaselineMs: Int64?
  @ObservationIgnored private var lastSeenPressTimestampMs: Int64?
  @ObservationIgnored private var lastLateNotice: Date?
  private static let latePressThresholdMs: Int64 = 5000
  @ObservationIgnored private var saidStillWorking = false
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceTask: Task<Void, Never>?

  init(sdkSetupError: String? = nil) {
    let wearables = Wearables.shared
    let selector = AutoDeviceSelector(wearables: wearables)
    self.wearables = wearables
    self.selector = selector
    self.camera = GlassesCamera(wearables: wearables, selector: selector)
    self.registrationState = wearables.registrationState
    self.hasAPIKey = Keychain.read(Self.apiKeyAccount) != nil
    self.useHighResPhoto = UserDefaults.standard.bool(forKey: Self.highResDefaultsKey)
    if let sdkSetupError {
      errorMessage =
        "The Meta glasses SDK failed to start, so glasses features may not work.\n\nDetails: \(sdkSetupError)"
    }

    registrationTask = Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.registrationState = state
      }
    }
    deviceTask = Task { [weak self] in
      for await deviceId in selector.activeDeviceStream() {
        self?.hasActiveDevice = deviceId != nil
      }
    }
  }

  // MARK: - API key

  func saveAPIKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    hasAPIKey = Keychain.save(trimmed, account: Self.apiKeyAccount)
    if !hasAPIKey { errorMessage = "Couldn't save the key to the Keychain." }
  }

  func deleteAPIKey() {
    Keychain.delete(Self.apiKeyAccount)
    hasAPIKey = false
  }

  // MARK: - Meta AI registration

  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        errorMessage = ErrorDetail.alertText(error)
      }
    }
  }

  func disconnectGlasses() {
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        errorMessage = ErrorDetail.alertText(error)
      }
    }
  }

  /// Forwards Meta AI callbacks (registration, permission) to the SDK.
  func handleOpenURL(_ url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else { return }
    Task {
      do {
        _ = try await wearables.handleUrl(url)
      } catch {
        errorMessage = ErrorDetail.alertText(error)
      }
    }
  }

  // MARK: - Solve

  func solve() async {
    guard !isBusy else { return }
    guard hasAPIKey else {
      errorMessage = "Add your Anthropic API key in Settings first."
      return
    }
    guard isRegistered else {
      errorMessage = "Connect your glasses first."
      return
    }
    if sessionActive && sessionPaused {
      errorMessage = GlassesError.sessionPaused.localizedDescription
      return
    }
    do {
      if try await wearables.checkPermissionStatus(.camera) == .granted {
        await run()
      } else {
        // Requesting permission jumps to the Meta AI app, so confirm first.
        showCameraPermissionPrompt = true
      }
    } catch {
      errorMessage = ErrorDetail.alertText(error)
    }
  }

  func confirmCameraPermission() async {
    showCameraPermissionPrompt = false
    let pendingPrompt = pendingSessionPrompt
    pendingSessionPrompt = nil
    do {
      let status = try await wearables.requestPermission(.camera)
      diag("permission", "requestPermission(.camera) -> \(status)")
      guard status == .granted else {
        errorMessage = "Camera permission wasn't granted in the Meta AI app."
        return
      }
      if let pendingPrompt {
        await beginSession(prompt: pendingPrompt)
      } else {
        await run()
      }
    } catch {
      diag("permission", "requestPermission(.camera) FAILED: \(ErrorDetail.describe(error))")
      errorMessage = ErrorDetail.alertText(error)
    }
  }

  func cancelCameraPermission() {
    showCameraPermissionPrompt = false
    pendingSessionPrompt = nil
  }

  func repeatAnswer() {
    guard !lastAnswer.isEmpty else { return }
    speaker.speak(lastAnswer)
  }

  func stopSpeaking() {
    speaker.stop()
  }

  private func run() async {
    guard let apiKey = Keychain.read(Self.apiKeyAccount) else {
      hasAPIKey = false
      return
    }
    // A capture-button press may wake the app in the background. iOS then allows roughly
    // 30 seconds; if that runs out mid-photo, stop the camera rather than be suspended with
    // a stream running (SDK issue #231).
    let backgroundActivity = BackgroundActivity(name: "Solve") { [weak self] in
      self?.camera.abortCapture()
    }
    saidStillWorking = false
    speaker.stop()
    defer {
      phase = .idle
      backgroundActivity.end()
    }
    let prompt = sessionActive ? sessionPrompt : ClaudeClient.defaultPrompt
    diag("solve", "start (app \(Self.appStateDescription), hands-free \(sessionActive))")

    let photo: Data
    do {
      phase = .capturing
      photo = try await camera.capturePhoto(highResolution: useHighResPhoto, keepSession: sessionActive)
      diag("solve", "photo received, \(photo.count) bytes; calling Claude")
    } catch {
      phase = .idle
      scheduleShutterRevive("after a failed photo", force: true)
      reportSolveFailure(error)
      speaker.endKeepAliveAfterSpeech()
      return
    }
    lastPhoto = UIImage(data: photo)
    phase = .thinking
    // A photo can drop button events, sometimes without saying so; re-add them while
    // Claude works, since the button can't be used until the answer is spoken anyway.
    scheduleShutterRevive("after a photo", force: true)

    // Claude can take longer than iOS's background allowance. Playing (silent) audio keeps
    // the app running until the spoken answer, which keeps it running to the end.
    speaker.beginKeepAlive()
    do {
      speaker.speak("Got it. Working on it.")
      let answer = try await ClaudeClient(apiKey: apiKey).solve(photo: photo, prompt: prompt)
      lastAnswer = answer
      diag("solve", "answer received, \(answer.count) characters (app \(Self.appStateDescription))")
      speaker.speak(answer)
    } catch {
      reportSolveFailure(error)
    }
    speaker.endKeepAliveAfterSpeech()
  }

  /// How much later this press arrived than the fastest press so far, in milliseconds.
  private func pressLateness(_ timestampMs: Int64) -> Int64 {
    if let last = lastSeenPressTimestampMs, timestampMs < last {
      pressOffsetBaselineMs = nil  // the glasses' clock restarted
    }
    lastSeenPressTimestampMs = timestampMs
    let offset = Int64(Date.now.timeIntervalSince1970 * 1000) - timestampMs
    let baseline = min(pressOffsetBaselineMs ?? offset, offset)
    pressOffsetBaselineMs = baseline
    return offset - baseline
  }

  private static var appStateDescription: String {
    switch UIApplication.shared.applicationState {
    case .active: "foreground"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }

  private func reportSolveFailure(_ error: Error) {
    diag("solve", "FAILED: \(ErrorDetail.describe(error))")
    errorMessage = ErrorDetail.alertText(error)
    // The user may be looking through the glasses, not at the phone.
    speaker.speak("Sorry. \(error.localizedDescription)")
  }

  // MARK: - Hands-free session

  /// Starts a session that stays open (also in the background) and solves on each press
  /// of the glasses' capture button, using `prompt`.
  func startSession(prompt: String) async {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    diag(
      "start", "Start Session tapped: registration \(registrationState), glasses detected \(hasActiveDevice), "
        + "API key \(hasAPIKey), already active \(sessionActive), starting \(isStartingSession)")
    guard !trimmed.isEmpty, !sessionActive, !isStartingSession else { return }
    guard hasAPIKey else {
      errorMessage = "Add your Anthropic API key in Settings first."
      return
    }
    guard isRegistered else {
      errorMessage = "Connect your glasses first."
      return
    }
    do {
      // Ask now: the Meta AI permission screen can't open from the lock screen later.
      let status = try await wearables.checkPermissionStatus(.camera)
      diag("permission", "checkPermissionStatus(.camera) -> \(status)")
      if status == .granted {
        await beginSession(prompt: trimmed)
      } else {
        pendingSessionPrompt = trimmed
        showCameraPermissionPrompt = true
      }
    } catch {
      diag("permission", "checkPermissionStatus(.camera) FAILED: \(ErrorDetail.describe(error))")
      errorMessage = ErrorDetail.alertText(error)
    }
  }

  func stopSession() {
    guard sessionActive else { return }
    diag("start", "Stop session tapped")
    sessionActive = false
    sessionStateTask?.cancel()
    sessionStateTask = nil
    shutterReviveTask?.cancel()
    shutterReviveTask = nil
    shutter.detach(from: camera.currentSession)
    camera.endSession()
    resetSessionState()
  }

  private func beginSession(prompt: String) async {
    isStartingSession = true
    defer { isStartingSession = false }
    let session: DeviceSession
    do {
      session = try await camera.startedSession()
    } catch {
      diag("start", "session start FAILED: \(ErrorDetail.describe(error))")
      errorMessage = ErrorDetail.alertText(error)
      return
    }
    diag("start", "session started; attaching capture button")
    sessionPrompt = prompt
    sessionActive = true
    sessionPaused = session.state == .paused
    observeSessionState(session)
    attachShutter(to: session)
    speaker.speak("Session started. Press the capture button to solve.")
  }

  private func observeSessionState(_ session: DeviceSession) {
    sessionStateTask?.cancel()
    let states = session.stateStream()
    sessionStateTask = Task { [weak self] in
      for await state in states {
        self?.sessionStateChanged(state, session: session)
      }
    }
  }

  private func sessionStateChanged(_ state: DeviceSessionState, session: DeviceSession) {
    diag("session", "hands-free session state -> \(state)")
    guard sessionActive else { return }
    switch state {
    case .started:
      if sessionPaused {
        sessionPaused = false
        // Button events may have dropped while paused; a resume earns a fresh set of tries.
        shutterAttempts = 0
        scheduleShutterRevive("session resumed")
      }
    case .paused:
      sessionPaused = true
    case .stopped:
      // Ended from the glasses (touchpad tap-and-hold, hinges closed) or lost connection.
      sessionActive = false
      sessionStateTask = nil
      shutterReviveTask?.cancel()
      shutterReviveTask = nil
      shutter.detach(from: nil)
      resetSessionState()
      speaker.speak("Glasses session ended.")
    case .idle, .starting, .stopping:
      break
    }
  }

  private func attachShutter(to session: DeviceSession) {
    shutterAttempts += 1
    shutter.attach(
      to: session,
      onPress: { [weak self] timestampMs in self?.shutterPressed(at: timestampMs) },
      onStatus: { [weak self] status in self?.shutterStatusChanged(status) }
    )
    shutterStatus = shutter.status
  }

  private func shutterStatusChanged(_ status: ShutterButton.Status) {
    shutterStatus = status
    switch status {
    case .active:
      shutterAttempts = 0
      shutterProblemReported = false
    case .activating:
      break
    case .off:
      // Dropped after being active, typically by a photo transfer.
      scheduleShutterRevive("button events dropped")
    case .unavailable(_, true):
      if shutterAttempts < Self.maxShutterAttempts {
        scheduleShutterRevive("retrying after an error")
      } else {
        reportShutterUnavailable()
      }
    case .unavailable(_, false):
      reportShutterUnavailable()
    }
  }

  /// Re-adds button events after they dropped or failed in a way a retry can fix. Waits a
  /// beat first (longer on each attempt), since the glasses can't take the request while a
  /// photo is still transferring or the link is still coming up.
  /// With `force`, an `active` capability is replaced too: Meta's sample saw one report
  /// `active` and deliver nothing, which can't be detected from here.
  private func scheduleShutterRevive(_ reason: String, force: Bool = false) {
    guard sessionActive else { return }
    if force {
      // A fresh cycle after each photo; replaces any pending, non-forced retry.
      shutterReviveTask?.cancel()
      shutterReviveTask = nil
      shutterAttempts = 0
    }
    guard shutterReviveTask == nil else { return }
    let delay = Duration.milliseconds(750 * max(1, shutterAttempts))
    shutterReviveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.shutterReviveTask = nil
      self.reviveShutter(reason, force: force)
    }
  }

  private func reviveShutter(_ reason: String, force: Bool = false) {
    switch shutterStatus {
    case .unavailable(_, false): return
    case .active, .activating: if !force { return }
    case .off, .unavailable(_, true): break
    }
    guard sessionActive, !sessionPaused, phase != .capturing,
      let session = camera.currentSession, session.state == .started
    else {
      // A later trigger (end of the photo, session resuming) tries again.
      diag("inputs", "re-add skipped (\(reason)): paused \(sessionPaused), phase \(phase)")
      return
    }
    guard shutterAttempts < Self.maxShutterAttempts else {
      reportShutterUnavailable()
      return
    }
    diag("inputs", "re-adding button events (\(reason)), attempt \(shutterAttempts + 1)")
    attachShutter(to: session)
  }

  private func reportShutterUnavailable() {
    guard !shutterProblemReported else { return }
    shutterProblemReported = true
    let reason: String
    if case .unavailable(let message, _) = shutterStatus {
      reason = message
    } else {
      reason = "Button events stopped and didn't come back after \(shutterAttempts) tries."
    }
    errorMessage =
      "The capture button can't trigger Solve. \(reason)\n\n"
      + "Still works: the session stays on, and the Solve button in this app uses your session prompt."
    // The wearer may not be looking at the phone.
    speaker.speak("The capture button isn't available. Use the Solve button in the app.")
  }

  private func shutterPressed(at timestampMs: Int64) {
    let lateness = pressLateness(timestampMs)
    diag(
      "inputs",
      "capture press: app \(Self.appStateDescription), \(lateness) ms later than the fastest delivery, "
        + "active \(sessionActive), busy \(isBusy), paused \(sessionPaused)")
    guard sessionActive else { return }
    if lateness > Self.latePressThresholdMs {
      // The view has likely changed since; a photo now wouldn't show what was pressed for.
      if lastLateNotice.map({ Date.now.timeIntervalSince($0) > 10 }) ?? true {
        lastLateNotice = .now
        speaker.speak("That button press reached the phone late. Press again.")
      }
      return
    }
    if let last = lastPressTimestampMs, timestampMs >= last, timestampMs - last < Self.pressDebounceMs {
      diag("inputs", "press ignored: \(timestampMs - last) ms after the previous one")
      return
    }
    lastPressTimestampMs = timestampMs
    guard !isBusy else {
      // Once per solve, so repeated presses don't keep cutting off the speech.
      if !saidStillWorking {
        saidStillWorking = true
        speaker.speak("Still working on the last one.")
      }
      return
    }
    guard !sessionPaused else {
      speaker.speak("The session is paused. Tap the touchpad once to resume.")
      return
    }
    Task { await run() }
  }

  private func resetSessionState() {
    sessionPaused = false
    shutterStatus = .off
    shutterAttempts = 0
    shutterProblemReported = false
    lastPressTimestampMs = nil
    lastSeenPressTimestampMs = nil
    pressOffsetBaselineMs = nil
    sessionPrompt = ClaudeClient.defaultPrompt
  }
}

/// Keeps the app running briefly after it leaves the foreground (iOS grants about 30 seconds).
@MainActor
private final class BackgroundActivity {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init(name: String, onExpire: @escaping @MainActor @Sendable () -> Void = {}) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      MainActor.assumeIsolated {
        diag("app", "background time for \(name) ran out")
        onExpire()
        self?.end()
      }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
