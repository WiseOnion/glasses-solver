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
  private static let speechRateDefaultsKey = "speechRate"
  private static let testModeDefaultsKey = "testMode"
  private static let writingTimeDefaultsKey = "writingTime"
  private static let voiceDefaultsKey = "voiceIdentifier"
  /// A sample in the style the system prompt asks for, including dictated Write lines.
  private static let sampleAnswer = """
    The derivative of sine of the quantity 3 x squared is 6 x cosine of the quantity 3 x squared, using the chain rule. You'll write two lines.
    First, the derivative of the outside function, sine, is cosine. Keep the inside the same, and multiply by the derivative of the inside, which is 6 x.
    Write: y prime, equals, cosine, open paren, 3 x squared, close paren, times, 6 x.
    Next, tidy up by moving the 6 x to the front.
    Write: y prime, equals, 6 x, cosine, open paren, 3 x squared, close paren.
    So the answer is 6 x cosine of the quantity 3 x squared.
    """

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
  /// Runs the full glasses flow but skips Claude: waits, then speaks a sample answer.
  /// Free to use, and the wait outlasts iOS's background allowance when the phone is
  /// locked, so it also tests that the app stays running.
  var testMode: Bool {
    didSet { UserDefaults.standard.set(testMode, forKey: Self.testModeDefaultsKey) }
  }
  var canSolve: Bool { hasAPIKey || testMode }

  /// How long to wait after each dictated Write line, as a multiple of the estimated
  /// writing time (see `Speaker.writingTimeRange`).
  var writingTime: Double {
    didSet {
      speaker.writingTimeScale = writingTime
      UserDefaults.standard.set(writingTime, forKey: Self.writingTimeDefaultsKey)
    }
  }

  /// The chosen voice's identifier; nil picks the best installed voice automatically.
  var voiceIdentifier: String? {
    didSet {
      speaker.voiceIdentifier = voiceIdentifier
      UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceDefaultsKey)
    }
  }

  /// Every solve, for the Conversation screen.
  @ObservationIgnored let conversation = ConversationStore()

  /// Speaking speed for answers (see `Speaker.rateRange`).
  var speechRate: Float {
    didSet {
      speaker.rate = speechRate
      UserDefaults.standard.set(speechRate, forKey: Self.speechRateDefaultsKey)
    }
  }

  /// Set the moment a solve is requested (before any await), so a second press or tap
  /// can't start a second photo while the first is still getting going.
  private(set) var solveInFlight = false
  var isBusy: Bool { phase != .idle || solveInFlight }
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
      if !canSolve { return "Add your Anthropic API key in Settings, or turn on Test mode." }
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
  /// A session refresh running in the background after a photo (see `refreshHandsFreeSession`).
  @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?
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
    self.testMode = UserDefaults.standard.bool(forKey: Self.testModeDefaultsKey)
    let savedRate = UserDefaults.standard.object(forKey: Self.speechRateDefaultsKey) as? Float
    self.speechRate = savedRate.map { min(max($0, Speaker.rateRange.lowerBound), Speaker.rateRange.upperBound) }
      ?? Speaker.defaultRate
    let savedWritingTime = UserDefaults.standard.object(forKey: Self.writingTimeDefaultsKey) as? Double
    self.writingTime = savedWritingTime.map {
      min(max($0, Speaker.writingTimeRange.lowerBound), Speaker.writingTimeRange.upperBound)
    } ?? 1
    self.voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey)
    // All stored properties are set from here on, so `self` can be used.
    speaker.rate = speechRate
    speaker.writingTimeScale = writingTime
    speaker.voiceIdentifier = voiceIdentifier
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
    solveInFlight = true
    defer { solveInFlight = false }
    guard canSolve else {
      errorMessage = "Add your Anthropic API key in Settings first, or turn on Test mode."
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
    if pendingPrompt == nil {
      guard !isBusy else { return }
      solveInFlight = true
    }
    defer { if pendingPrompt == nil { solveInFlight = false } }
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

  /// Says the latest "Write:" line again (touchpad double-tap or the on-screen button).
  func repeatWriteLine() {
    if !speaker.repeatLastWriteLine() {
      diag("audio", "repeat requested, but there's no Write line yet")
    }
  }

  /// A sample in the style the system prompt asks for, to judge speed and voice.
  func testVoice() {
    speaker.speak(Self.sampleAnswer)
  }

  var voiceDescription: String {
    guard let voice = speaker.resolvedVoice else { return "System default voice" }
    return "\(voice.name), \(Speaker.qualityName(voice.quality)) quality"
  }

  /// Installed voices for the Settings picker: (identifier, label), best quality first.
  var availableVoices: [(id: String, label: String)] {
    Speaker.availableVoices().map { voice in
      let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
      return (voice.identifier, "\(voice.name) · \(Speaker.qualityName(voice.quality)) · \(region)")
    }
  }

  /// Says one sentence in the current voice and speed.
  func previewVoice() {
    speaker.speak("Hi. This is how your answers will sound. The derivative of x squared is 2 x.")
  }

  /// Speaks a past answer again from the Conversation screen.
  func replay(_ entry: ConversationEntry) {
    guard let answer = entry.answer else { return }
    speaker.speak(answer)
  }

  private func run() async {
    let apiKey = Keychain.read(Self.apiKeyAccount)
    guard apiKey != nil || testMode else {
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
    // Captured now, so an answer that arrives after the session ends still files under it.
    let chatSessionID = conversation.currentSessionID
    diag("solve", "start (app \(Self.appStateDescription), hands-free \(sessionActive), test mode \(testMode))")

    let photo: Data
    do {
      phase = .capturing
      // A refresh started after the previous photo must finish before this one.
      await sessionRefreshTask?.value
      photo = try await captureWithRecovery()
      diag("solve", "photo received, \(photo.count) bytes; calling Claude")
    } catch {
      phase = .idle
      scheduleShutterRevive("after a failed photo", force: true)
      reportSolveFailure(error)
      conversation.add(
        prompt: prompt, photo: nil, answer: nil, error: error.localizedDescription, isTest: testMode,
        sessionID: chatSessionID)
      speaker.endKeepAliveAfterSpeech()
      return
    }
    lastPhoto = UIImage(data: photo)
    phase = .thinking
    // In SDK 1.0.0 a second camera stream in the same session can fail at once (Meta, SDK
    // issue #260), so each photo gets a fresh session. Refresh now, while Claude works and
    // the button can't be used anyway; this also re-adds the button events a photo can drop.
    if sessionActive {
      startSessionRefresh(reason: "fresh camera for the next photo")
    } else {
      camera.endSession()
    }

    // Claude can take longer than iOS's background allowance. Playing (silent) audio keeps
    // the app running until the spoken answer, which keeps it running to the end.
    speaker.beginKeepAlive()
    do {
      speaker.speak("Got it. Working on it.")
      let answer: String
      if let apiKey, !testMode {
        answer = try await ClaudeClient(apiKey: apiKey).solve(photo: photo, prompt: prompt)
      } else {
        answer = try await simulatedAnswer(photo: photo)
      }
      lastAnswer = answer
      diag("solve", "answer received, \(answer.count) characters (app \(Self.appStateDescription))")
      speaker.speak(answer)
      conversation.add(
        prompt: prompt, photo: photo, answer: answer, error: nil, isTest: testMode, sessionID: chatSessionID)
    } catch {
      reportSolveFailure(error)
      conversation.add(
        prompt: prompt, photo: photo, answer: nil, error: error.localizedDescription, isTest: testMode,
        sessionID: chatSessionID)
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

  /// Test mode's stand-in for Claude. Locked, it waits longer than iOS's ~30-second
  /// background allowance, so hearing the answer means the keep-alive worked.
  private func simulatedAnswer(photo: Data) async throws -> String {
    let inBackground = UIApplication.shared.applicationState != .active
    let wait: Duration = inBackground ? .seconds(35) : .seconds(2)
    diag("solve", "test mode: waiting \(wait) instead of calling Claude (app \(Self.appStateDescription))")
    try await Task.sleep(for: wait)
    diag("solve", "test mode: wait finished (app \(Self.appStateDescription))")
    let kilobytes = photo.count / 1024
    return "Test mode. The photo arrived, \(kilobytes) kilobytes"
      + (inBackground ? ", and the app stayed running with the phone locked. " : ". ")
      + Self.sampleAnswer
  }

  /// Takes the photo; if the camera fails in a way a fresh glasses session fixes, starts one
  /// and tries once more.
  private func captureWithRecovery() async throws -> Data {
    do {
      return try await camera.capturePhoto(highResolution: useHighResPhoto, keepSession: sessionActive)
    } catch let error as GlassesError where error.isFixedByFreshSession {
      diag("solve", "photo failed (\(ErrorDetail.describe(error))); retrying once with a fresh glasses session")
      if sessionActive {
        try await refreshHandsFreeSession(reason: "photo failed")
      } else {
        camera.endSession()
      }
      return try await camera.capturePhoto(highResolution: useHighResPhoto, keepSession: sessionActive)
    }
  }

  private func startSessionRefresh(reason: String) {
    sessionRefreshTask = Task { [weak self] in
      try? await self?.refreshHandsFreeSession(reason: reason)
      self?.sessionRefreshTask = nil
    }
  }

  /// Replaces the hands-free session's glasses connection with a new one, keeping the
  /// session itself (prompt, chat, indicator) going, and re-attaches the button.
  private func refreshHandsFreeSession(reason: String) async throws {
    guard sessionActive else { return }
    diag("session", "refreshing the glasses session (\(reason))")
    // Stop watching the old connection first, so its ending isn't taken as the user's.
    sessionStateTask?.cancel()
    sessionStateTask = nil
    shutterReviveTask?.cancel()
    shutterReviveTask = nil
    shutter.detach(from: camera.currentSession)
    shutterStatus = .off
    do {
      let session = try await camera.refreshSession()
      guard sessionActive else {
        camera.endSession()  // stopped while reconnecting
        return
      }
      sessionPaused = session.state == .paused
      observeSessionState(session)
      shutterAttempts = 0
      attachShutter(to: session)
      diag("session", "glasses session refreshed")
    } catch {
      diag("session", "refresh FAILED: \(ErrorDetail.describe(error))")
      if sessionActive {
        sessionActive = false
        resetSessionState()
        conversation.endSession()
        errorMessage = ErrorDetail.alertText(error)
        speaker.speak("Lost the connection to the glasses. Start the session again.")
      }
      throw error
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
    guard canSolve else {
      errorMessage = "Add your Anthropic API key in Settings first, or turn on Test mode."
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
    conversation.endSession()
  }

  private func beginSession(prompt: String) async {
    isStartingSession = true
    defer { isStartingSession = false }
    // A reconnect from the previous session may still be running; one session at a time.
    await sessionRefreshTask?.value
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
    conversation.beginSession(prompt: prompt)
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
      conversation.endSession()
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
      onSelect: { [weak self] in self?.repeatWriteLine() },
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
    solveInFlight = true
    Task {
      await run()
      solveInFlight = false
    }
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
