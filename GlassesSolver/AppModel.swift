import AVFoundation
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
  /// A new key when the default changed to Apple's normal speed, so an old, slower saved
  /// speed (which made voices sound robotic) starts over at the new default once.
  private static let speechRateDefaultsKey = "speechRate.v2"
  private static let testModeDefaultsKey = "testMode"
  private static let writingTimeDefaultsKey = "writingTime"
  private static let voiceDefaultsKey = "voiceIdentifier"
  private static let dictateInPartsDefaultsKey = "dictateInParts"
  /// The old on/off switch for the built-in voice, read once to keep a choice of "off".
  private static let neuralVoiceDefaultsKey = "useNeuralVoice"
  private static let voiceEngineDefaultsKey = "voiceEngine"
  private static let azureKeyAccount = "azure-speech-key"
  private static let azureRegionDefaultsKey = "azureRegion"
  private static let azureVoiceDefaultsKey = "azureVoice"
  /// A sample in the style the system prompt asks for, including dictated Write lines.
  private static let sampleAnswer = """
    I can see problem 3.
    Problem: 3
    This is the derivative of g of w, equals, 1 plus tangent w, over 6 minus w cubed, by the quotient rule.
    You'll write six lines.
    First, write down u, v and their derivatives.
    Write: u equals, 1, plus tangent w
    Write: u prime equals, secant squared w
    Write: v equals, 6, minus w cubed
    Write: v prime equals, negative 3 w squared
    Now put them into the quotient rule.
    Write: g prime of w equals, a fraction
    Continue: on top, you have open parenthesis, secant squared w, close parenthesis, times open parenthesis, 6 minus w cubed, close parenthesis
    Continue: minus, open parenthesis, 1 plus tangent w, close parenthesis, times open parenthesis, negative 3 w squared, close parenthesis
    Continue: on the bottom, you have open parenthesis, 6 minus w cubed, close parenthesis, squared
    Check: Just to make sure you got all that, line 5 should look like g prime of w equals a fraction, with secant squared w in parentheses, times 6 minus w cubed in parentheses, minus 1 plus tangent w in parentheses, times negative 3 w squared in parentheses, all on top, and 6 minus w cubed in parentheses, squared, on the bottom.
    Now simplify the top. This is the answer.
    Write: g prime of w equals, a fraction
    Continue: on top, you have open parenthesis, 6 minus w cubed, close parenthesis, times secant squared w
    Continue: plus 3 w squared, times open parenthesis, 1 plus tangent w, close parenthesis
    Continue: on the bottom, you have open parenthesis, 6 minus w cubed, close parenthesis, squared
    Check: So line 6 reads g prime of w equals a fraction, with 6 minus w cubed in parentheses times secant squared w, plus 3 w squared times 1 plus tangent w in parentheses, on top, and 6 minus w cubed in parentheses, squared, on the bottom.
    Mark: Draw a box around line 6.
    Done.
    """

  /// The limit definition, worked the way the course wants it: problem 4 of the practice test.
  private static let limitSampleAnswer = """
    I can see problem 4.
    Problem: 4
    This is the derivative of f of x, equals, negative 3 x squared plus 8 x minus 2, using the limit definition.
    You'll write seven lines.
    First, write the limit definition.
    Write: f prime of x equals, the limit as h approaches 0, of a fraction
    Continue: on top, you have f of, open parenthesis, x plus h, close parenthesis, minus f of x
    Continue: on the bottom, you have h
    Now put in f of x plus h and f of x.
    Write: equals, the limit as h approaches 0, of a fraction
    Continue: on top, you have open parenthesis, negative 3, times open parenthesis, x plus h, close parenthesis, squared, plus 8, times open parenthesis, x plus h, close parenthesis, minus 2, close parenthesis
    Continue: minus, open parenthesis, negative 3 x squared, plus 8 x, minus 2, close parenthesis
    Continue: on the bottom, you have h
    Now expand, and distribute the minus sign.
    Write: equals, the limit as h approaches 0, of a fraction
    Continue: on top, you have negative 3 x squared, minus 6 x h, minus 3 h squared, plus 8 x, plus 8 h, minus 2
    Continue: plus 3 x squared, minus 8 x, plus 2
    Continue: on the bottom, you have h
    Now combine like terms.
    Write: equals, the limit as h approaches 0, of a fraction
    Continue: on top, you have negative 6 x h, minus 3 h squared, plus 8 h
    Continue: on the bottom, you have h
    Now factor out h.
    Write: equals, the limit as h approaches 0, of a fraction
    Continue: on top, you have h, times open parenthesis, negative 6 x, minus 3 h, plus 8, close parenthesis
    Continue: on the bottom, you have h
    Now cancel the h.
    Mark: On line 5, cross out both h's, the h on top in front of the parentheses and the h on the bottom.
    Write: equals, the limit as h approaches 0, of negative 6 x, minus 3 h, plus 8
    Now plug in 0 for h. This is the answer.
    Write: equals negative 6 x, plus 8
    Mark: Draw a box around line 7.
    Done.
    """

  private(set) var registrationState: RegistrationState
  private(set) var hasActiveDevice = false
  private(set) var phase: Phase = .idle
  private(set) var lastPhoto: UIImage?
  private(set) var lastAnswer = ""
  private(set) var hasAPIKey: Bool
  /// True while speech is paused because the glasses' audio disconnected (see `Speaker.heldForRoute`).
  private(set) var speechHeld = false

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

  /// Dictate Write lines a few words at a time with a writing pause after each part (true),
  /// or the whole line and then one pause.
  var dictateInParts: Bool {
    didSet {
      speaker.dictateInParts = dictateInParts
      UserDefaults.standard.set(dictateInParts, forKey: Self.dictateInPartsDefaultsKey)
    }
  }

  /// Which voice reads answers.
  enum VoiceEngine: String, CaseIterable {
    /// Microsoft's neural voices, online, with the user's own key.
    case azure
    /// Kokoro Heart, built into the app, offline.
    case heart
    /// An Apple voice, picked below.
    case apple
  }

  /// Which voice reads answers. Azure needs a saved key (and falls back to Heart when it
  /// can't be reached); Heart needs a build with its files.
  var voiceEngine: VoiceEngine {
    didSet {
      UserDefaults.standard.set(voiceEngine.rawValue, forKey: Self.voiceEngineDefaultsKey)
      applyVoiceEngine()
    }
  }

  /// True when this build includes the built-in voice.
  var hasNeuralVoice: Bool { NeuralVoice.isBundled }

  /// The Azure Speech resource's region, such as "eastus".
  var azureRegion: String {
    didSet {
      UserDefaults.standard.set(azureRegion, forKey: Self.azureRegionDefaultsKey)
      applyVoiceEngine()
    }
  }

  /// The Azure voice, such as "en-US-AvaMultilingualNeural".
  var azureVoiceName: String {
    didSet {
      UserDefaults.standard.set(azureVoiceName, forKey: Self.azureVoiceDefaultsKey)
      applyVoiceEngine()
    }
  }

  /// Azure voices to choose from: clear US English voices with full SSML support.
  static let azureVoices = [
    "en-US-AvaMultilingualNeural", "en-US-AndrewMultilingualNeural", "en-US-EmmaMultilingualNeural",
    "en-US-BrianMultilingualNeural",
  ]

  private(set) var hasAzureKey: Bool

  /// Tells the speaker which voice to use, from the setting and the saved Azure key.
  private func applyVoiceEngine() {
    speaker.useNeuralVoice = voiceEngine != .apple
    if voiceEngine == .azure, let key = Keychain.read(Self.azureKeyAccount), !azureRegion.isEmpty {
      speaker.azureVoice = NeuralVoice.AzureVoice(key: key, region: azureRegion, voice: azureVoiceName)
    } else {
      speaker.azureVoice = nil
    }
    speaker.preloadNeuralVoice()
  }

  func saveAzureKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    hasAzureKey = Keychain.save(trimmed, account: Self.azureKeyAccount)
    if !hasAzureKey { errorMessage = "Couldn't save the Azure key to the Keychain." }
    applyVoiceEngine()
  }

  func deleteAzureKey() {
    Keychain.delete(Self.azureKeyAccount)
    hasAzureKey = false
    applyVoiceEngine()
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
  /// True once the current answer's first piece has arrived and begun being spoken.
  @ObservationIgnored private var answerStarted = false
  /// When `lastAnswer` arrived. A photo within `followUpWindow` of it is sent as a follow-up.
  @ObservationIgnored private var lastAnswerTime: Date?
  private static let followUpWindow: TimeInterval = 60 * 60
  /// How far `lastAnswer` got before a photo or Stop cut it short; nil if heard to the end.
  @ObservationIgnored private var lastAnswerStoppedAt: Speaker.Progress?
  /// How often "Still working." is said while waiting for the answer's first words.
  private static let stillWorkingInterval = Duration.seconds(20)
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
    self.dictateInParts = UserDefaults.standard.object(forKey: Self.dictateInPartsDefaultsKey) as? Bool ?? true
    let hasAzureKey = Keychain.read(Self.azureKeyAccount) != nil
    self.hasAzureKey = hasAzureKey
    self.azureRegion = UserDefaults.standard.string(forKey: Self.azureRegionDefaultsKey) ?? "eastus"
    self.azureVoiceName = UserDefaults.standard.string(forKey: Self.azureVoiceDefaultsKey) ?? Self.azureVoices[0]
    // A saved choice, else the best voice available: Azure with a key, then Heart, then
    // Apple. Turning the old "natural voice" switch off meant Apple.
    let savedEngine = UserDefaults.standard.string(forKey: Self.voiceEngineDefaultsKey).flatMap(VoiceEngine.init)
    let oldNaturalVoiceOff = UserDefaults.standard.object(forKey: Self.neuralVoiceDefaultsKey) as? Bool == false
    self.voiceEngine =
      savedEngine ?? (oldNaturalVoiceOff ? .apple : hasAzureKey ? .azure : NeuralVoice.isBundled ? .heart : .apple)
    // All stored properties are set from here on, so `self` can be used.
    speaker.rate = speechRate
    speaker.writingTimeScale = writingTime
    speaker.voiceIdentifier = voiceIdentifier
    speaker.dictateInParts = dictateInParts
    speaker.onHoldChanged = { [weak self] held in self?.speechHeld = held }
    applyVoiceEngine()
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
    speaker.speak(lastAnswer, isAnswer: true)
  }

  func stopSpeaking() {
    speaker.stop()
  }

  /// Plays speech held for the glasses' audio through the phone instead.
  func playOnPhone() {
    speaker.playOnPhone()
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

  /// The limit definition worked in full, to practice copying a long answer.
  func testLimitDefinition() {
    speaker.speak(Self.limitSampleAnswer)
  }

  var voiceDescription: String {
    if speaker.neuralVoiceActive { return speaker.neuralVoiceName }
    guard let voice = speaker.resolvedVoice else { return "System default voice" }
    let description = "\(voice.name), \(Speaker.qualityName(voice.quality)) quality"
    // Say so when the picked voice can't be found, instead of quietly switching.
    return speaker.chosenVoiceIsMissing
      ? "\(description). The voice you picked isn't available to this app right now, so this one is used instead"
      : description
  }

  /// Installed voices for the Settings picker: (identifier, label), best quality first.
  var availableVoices: [(id: String, label: String)] {
    Speaker.availableVoices().map { voice in
      let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
      let source = Speaker.isFromOtherApp(voice) ? " · other app" : ""
      return (voice.identifier, "\(voice.name) · \(Speaker.qualityName(voice.quality)) · \(region)\(source)")
    }
  }

  /// Writes every voice iOS reports to the diagnostics log, so a voice that doesn't show
  /// up in the picker can be traced (is iOS giving it to apps at all, and how is it labeled).
  func logInstalledVoices() {
    let all = AVSpeechSynthesisVoice.speechVoices()
    let others = all.filter(Speaker.isFromOtherApp)
    diag("voices", "iOS reports \(all.count) voices, \(others.count) from other apps")
    for voice in others + all.filter({ !Speaker.isFromOtherApp($0) && Speaker.isPhoneLanguage($0.language) }) {
      diag(
        "voices",
        "\(voice.name) | \(voice.language) | \(Speaker.qualityName(voice.quality)) | \(voice.identifier)")
    }
  }

  /// Says one sentence in the current voice and speed.
  func previewVoice() {
    // A real piece of dictation, with its pauses, rather than a sentence of ordinary speech.
    speaker.speak("Write: cosine of, open parenthesis, 3 x squared, close parenthesis, times secant squared x")
  }

  /// The same real line of dictation in each of the best voices, one after another.
  func compareVoices() {
    speaker.compareVoices(Speaker.comparisonVoices())
  }

  /// Sets the speaking speed so the current voice speaks about 150 words a minute: speaks a
  /// sentence, measures it, and scales the speed once. Tap it again to fine-tune.
  func matchSpeed() {
    speaker.speak(Speaker.calibrationText)
    speaker.measurementHandler = { [weak self] wpm in
      guard let self, (60...400).contains(wpm) else { return }
      let scaled = Float(Double(self.speechRate) * 150 / Double(wpm))
      let matched = min(max(scaled, Speaker.rateRange.lowerBound), Speaker.rateRange.upperBound)
      diag("audio", "matching speed: \(wpm) words per minute at \(self.speechRate), trying \(matched)")
      self.speechRate = matched
    }
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
    // Where the last answer was, if this photo cut it short (or Stop did), before stopping it.
    // Kept until a new answer arrives, so a photo that fails doesn't lose it.
    if let progress = speaker.progress { lastAnswerStoppedAt = progress }
    let stoppedAt = lastAnswerStoppedAt
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
    answerStarted = false
    speaker.speak("Got it. Working on it.")
    // Claude can think for a minute before the first words; say so now and then, so the
    // silence doesn't sound like the app stopped.
    let waitingCue = Task { [weak self] in
      while true {
        try? await Task.sleep(for: Self.stillWorkingInterval)
        guard !Task.isCancelled, let self, !self.answerStarted else { return }
        self.speaker.announce("Still working.", ifBusy: .skip)
      }
    }
    defer { waitingCue.cancel() }
    do {
      // The answer is spoken as it arrives, so the first problem starts while Claude is
      // still writing the rest.
      let reply: ClaudeClient.Answer
      if let apiKey, !testMode {
        // A photo taken soon after an answer goes as a follow-up to it, so a photo of the
        // listener's own work can be checked and continued from where they stopped.
        let previous = lastAnswerTime.map { Date.now.timeIntervalSince($0) < Self.followUpWindow } == true
          ? lastAnswer : nil
        let stopNote = previous == nil ? nil : stoppedAt.map(Self.describeStop)
        if previous != nil { diag("solve", "sending as a follow-up to the last answer. \(stopNote ?? "It was heard to the end.")") }
        reply = try await ClaudeClient(apiKey: apiKey).solve(
          photo: photo, prompt: prompt, previousAnswer: previous, stoppedAt: stopNote
        ) {
          [weak self] piece in
          self?.answerArrived(piece)
        }
      } else {
        let text = try await simulatedAnswer(photo: photo)
        answerArrived(text)
        reply = ClaudeClient.Answer(text: text, stopReason: "end_turn")
      }
      // An answer that ended early says so, and where, rather than sounding complete.
      let cutOff: Speaker.CutOff? =
        switch reply.stopReason {
        case "end_turn", "stop_sequence": nil
        case "max_tokens", "model_context_window_exceeded": .ranOut
        case nil: .dropped
        default: .stopped
        }
      let notice = cutOff.map { Speaker.cutOffNotice($0, answer: reply.text) }
      speaker.finishAnswer(notice: notice)
      let answer = [reply.text.trimmingCharacters(in: .whitespacesAndNewlines), notice]
        .compactMap { $0 }.joined(separator: "\n")
      lastAnswer = answer
      lastAnswerStoppedAt = nil
      // A Test mode sample isn't a real answer, so it's never sent as one to follow up on.
      lastAnswerTime = testMode ? nil : .now
      diag(
        "solve",
        "answer received, \(reply.text.count) characters, ended by \(reply.stopReason ?? "a dropped connection") "
          + "(app \(Self.appStateDescription))")
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

  /// Tells Claude how much of its last answer was heard before a new photo cut it short.
  nonisolated static func describeStop(_ progress: Speaker.Progress) -> String {
    let heard =
      if progress.line == 0 {
        "I'd heard you start problem \(progress.problem), but none of its lines yet"
      } else if progress.lineFinished {
        "I'd heard problem \(progress.problem) up to the end of line \(progress.line)"
      } else {
        "I'd heard problem \(progress.problem) up to partway through line \(progress.line)"
      }
    return "Your dictation was cut short when I took this photo: \(heard), and nothing after that."
  }

  /// Speaks the next piece of an answer, starting the answer with the first piece.
  private func answerArrived(_ piece: String) {
    if !answerStarted {
      answerStarted = true
      speaker.beginAnswer()
    }
    speaker.continueAnswer(piece)
  }

  /// How much later this press arrived than the fastest press so far, in milliseconds.
  private func pressLateness(_ timestampMs: Int64) -> Int64 {
    guard timestampMs > 0 else { return 0 }  // no timestamp: can't tell, so don't drop it
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
        speaker.announce("Lost the connection to the glasses. Start the session again.", ifBusy: .after)
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
      speaker.announce("Glasses session ended.", ifBusy: .after)
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
    speaker.announce("The capture button isn't available. Use the Solve button in the app.", ifBusy: .after)
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
        speaker.announce("That button press reached the phone late. Press again.", ifBusy: .skip)
      }
      return
    }
    if timestampMs > 0, let last = lastPressTimestampMs, timestampMs >= last,
      timestampMs - last < Self.pressDebounceMs
    {
      diag("inputs", "press ignored: \(timestampMs - last) ms after the previous one")
      return
    }
    lastPressTimestampMs = timestampMs
    guard !isBusy else {
      // Once per solve, so repeated presses don't keep cutting off the speech.
      if !saidStillWorking {
        saidStillWorking = true
        speaker.announce("Still working on the last one.", ifBusy: .skip)
      }
      return
    }
    guard !sessionPaused else {
      speaker.announce("The session is paused. Tap the touchpad once to resume.", ifBusy: .skip)
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
