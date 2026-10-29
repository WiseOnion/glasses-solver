import AVFoundation
import Foundation
import MWDATCore
import Observation
import Photos
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
  private static let savePhotosDefaultsKey = "savePhotosToLibrary"
  /// A new key when the default changed to Apple's normal speed, so an old, slower saved
  /// speed (which made voices sound robotic) starts over at the new default once.
  private static let speechRateDefaultsKey = "speechRate.v2"
  private static let testModeDefaultsKey = "testMode"
  private static let fastAnswersDefaultsKey = "fastAnswers"
  private static let subjectDefaultsKey = "subject"
  private static let photoActionDefaultsKey = "photoAction"
  private static let writingTimeDefaultsKey = "writingTime"
  private static let voiceDefaultsKey = "voiceIdentifier"
  private static let dictateInPartsDefaultsKey = "dictateInParts"
  /// The old on/off switch for the built-in voice, read once to keep a choice of "off".
  private static let neuralVoiceDefaultsKey = "useNeuralVoice"
  private static let voiceEngineDefaultsKey = "voiceEngine"
  private static let azureKeyAccount = "azure-speech-key"
  private static let azureRegionDefaultsKey = "azureRegion"
  private static let azureVoiceDefaultsKey = "azureVoice"
  private static let reverseSwipesDefaultsKey = "reverseSwipes"
  /// A sample in the style the system prompt asks for, including dictated Write lines.
  private static let sampleAnswer = """
    I can see problem 3.
    Problem: 3
    This is the derivative of g of w, equals, 1 plus tangent w, over 6 minus w cubed, by the quotient rule.
    You'll write six lines.
    First, write down u, v and their derivatives.
    Write: u equals, 1, plus tangent w || u = 1 + \\tan w
    Write: u prime equals, secant squared w || u' = \\sec^2 w
    Write: v equals, 6, minus w cubed || v = 6 - w^3
    Write: v prime equals, negative 3 w squared || v' = -3w^2
    Now put them into the quotient rule.
    Write: g prime of w equals, a fraction || g'(w) = \\frac{(\\sec^2 w)(6 - w^3) - (1 + \\tan w)(-3w^2)}{(6 - w^3)^2}
    Continue: on top, you have open parenthesis, secant squared w, close parenthesis, times open parenthesis, 6 minus w cubed, close parenthesis
    Continue: minus, open parenthesis, 1 plus tangent w, close parenthesis, times open parenthesis, negative 3 w squared, close parenthesis
    Continue: on the bottom, you have open parenthesis, 6 minus w cubed, close parenthesis, squared
    Check: Just to make sure you got all that, line 5 should look like g prime of w equals a fraction, with secant squared w in parentheses, times 6 minus w cubed in parentheses, minus 1 plus tangent w in parentheses, times negative 3 w squared in parentheses, all on top, and 6 minus w cubed in parentheses, squared, on the bottom.
    Now simplify the top. This is the answer.
    Write: g prime of w equals, a fraction || g'(w) = \\frac{(6 - w^3)\\sec^2 w + 3w^2(1 + \\tan w)}{(6 - w^3)^2}
    Continue: on top, you have open parenthesis, 6 minus w cubed, close parenthesis, times secant squared w
    Continue: plus 3 w squared, times open parenthesis, 1 plus tangent w, close parenthesis
    Continue: on the bottom, you have open parenthesis, 6 minus w cubed, close parenthesis, squared
    Check: So line 6 reads g prime of w equals a fraction, with 6 minus w cubed in parentheses times secant squared w, plus 3 w squared times 1 plus tangent w in parentheses, on top, and 6 minus w cubed in parentheses, squared, on the bottom.
    Mark: Draw a box around line 6.
    Done.
    """

  /// A chemistry answer in the style its system prompt asks for: questions 7 and 13 of the
  /// CHM 106 practice exam (multiple choice), then part B of the dimensional analysis quiz
  /// (work shown), so both kinds are heard.
  private static let chemistrySampleAnswer = """
    I can see questions 7 and 13, and part B.
    Problem: 7
    Answer: B, as in boy. Krypton core, 5 ess 2, 4 dee 10, 5 pee 5. || \\text{B}\\quad [\\mathrm{Kr}]\\,5s^2\\,4d^{10}\\,5p^5
    Problem: 13
    Answer: D, as in dog. 1.56 times 10 to the 23rd. || \\text{D}\\quad 1.56\\times10^{23}
    Problem: part B
    This is the mass of helium in the balloon, from its density.
    You'll write two lines.
    First, use the density to get grams.
    Write: mass equals, 1 point 2 7 7 times 10 to the 4th cubic centimeters, times, 1 point 7 8 6 times 10 to the negative 4th grams over 1 cubic centimeter, equals, 2 point 2 8 0 7 grams || m = 1.277\\times10^{4}\\text{ cm}^3 \\times \\frac{1.786\\times10^{-4}\\text{ g}}{1\\text{ cm}^3} = 2.2807\\text{ g}
    Mark: On line 1, cross out both cubic centimeters, the one after 10 to the 4th and the one on the bottom. || line 1: m = 1.277\\times10^{4}\\,\\cancel{\\text{cm}^3} \\times \\frac{1.786\\times10^{-4}\\text{ g}}{1\\,\\cancel{\\text{cm}^3}} = 2.2807\\text{ g}
    Now round to three significant figures. This is the answer.
    Write: mass equals, 2 point 2 8 grams || m = 2.28\\text{ g}
    Mark: Draw a box around line 2.
    Mark: In the blank for part B, write 2 point 2 8.
    Done.
    """

  /// The sample for the subject in use.
  private var subjectSample: String { subject == .chemistry ? Self.chemistrySampleAnswer : Self.sampleAnswer }

  /// The limit definition, worked the way the course wants it: problem 4 of the practice test.
  private static let limitSampleAnswer = """
    I can see problem 4.
    Problem: 4
    This is the derivative of f of x, equals, negative 3 x squared plus 8 x minus 2, using the limit definition.
    You'll write seven lines.
    First, write the limit definition.
    Write: f prime of x equals, the limit as h approaches 0, of a fraction || f'(x) = \\lim_{h \\to 0} \\frac{f(x + h) - f(x)}{h}
    Continue: on top, you have f of, open parenthesis, x plus h, close parenthesis, minus f of x
    Continue: on the bottom, you have h
    Now put in f of x plus h and f of x.
    Write: equals, the limit as h approaches 0, of a fraction || = \\lim_{h \\to 0} \\frac{\\left(-3(x + h)^2 + 8(x + h) - 2\\right) - \\left(-3x^2 + 8x - 2\\right)}{h}
    Continue: on top, you have open parenthesis, negative 3, times open parenthesis, x plus h, close parenthesis, squared, plus 8, times open parenthesis, x plus h, close parenthesis, minus 2, close parenthesis
    Continue: minus, open parenthesis, negative 3 x squared, plus 8 x, minus 2, close parenthesis
    Continue: on the bottom, you have h
    Now expand, and distribute the minus sign.
    Write: equals, the limit as h approaches 0, of a fraction || = \\lim_{h \\to 0} \\frac{-3x^2 - 6xh - 3h^2 + 8x + 8h - 2 + 3x^2 - 8x + 2}{h}
    Continue: on top, you have negative 3 x squared, minus 6 x h, minus 3 h squared, plus 8 x, plus 8 h, minus 2
    Continue: plus 3 x squared, minus 8 x, plus 2
    Continue: on the bottom, you have h
    Now combine like terms.
    Write: equals, the limit as h approaches 0, of a fraction || = \\lim_{h \\to 0} \\frac{-6xh - 3h^2 + 8h}{h}
    Continue: on top, you have negative 6 x h, minus 3 h squared, plus 8 h
    Continue: on the bottom, you have h
    Now factor out h.
    Write: equals, the limit as h approaches 0, of a fraction || = \\lim_{h \\to 0} \\frac{h(-6x - 3h + 8)}{h}
    Continue: on top, you have h, times open parenthesis, negative 6 x, minus 3 h, plus 8, close parenthesis
    Continue: on the bottom, you have h
    Now cancel the h.
    Mark: On line 5, cross out both h's, the h on top in front of the parentheses and the h on the bottom. || line 5: = \\lim_{h \\to 0} \\frac{\\cancel{h}(-6x - 3h + 8)}{\\cancel{h}}
    Write: equals, the limit as h approaches 0, of negative 6 x, minus 3 h, plus 8 || = \\lim_{h \\to 0} (-6x - 3h + 8)
    Now plug in 0 for h. This is the answer.
    Write: equals negative 6 x, plus 8 || = -6x + 8
    Mark: Draw a box around line 7.
    Done.
    """

  private(set) var registrationState: RegistrationState
  private(set) var hasActiveDevice = false
  private(set) var phase: Phase = .idle {
    didSet {
      speaker.photoInProgress = phase == .capturing
      updateActivity()
    }
  }
  private(set) var lastPhoto: UIImage?
  private(set) var lastAnswer = ""
  /// The answer shown on the phone: the one arriving now (as it comes), or the last one.
  private(set) var shownAnswer = ""
  /// The problem and line being said now, to mark it in the written answer.
  private(set) var linePosition: LinePosition?

  struct LinePosition: Equatable {
    let problem: String
    let line: Int
  }
  private(set) var hasAPIKey: Bool

  // Math: the current photo's problems, which the glasses' buttons act on (MathWorkspace).
  private(set) var workspace: MathWorkspace?
  /// The problem being shown and acted on, for the phone.
  var currentProblem: (label: String, problem: MathProblem?)? {
    guard let label = workspace?.currentLabel else { return nil }
    return (label, workspace?.problems[label])
  }
  /// True while Check is working on the current photo.
  private(set) var isChecking = false
  /// Counts photos started, so the phone can open the written answer for each new one.
  private(set) var photosStarted = 0
  /// The photo a new capture just replaced, kept only so a double press the glasses reported
  /// as a short press plus a double press can still check it (see `gestureArrived`).
  @ObservationIgnored private var displacedWorkspace: MathWorkspace?
  /// A new photo can start unless the camera is already taking one: latest capture wins, but
  /// captures never queue up.
  var canStartPhoto: Bool { phase != .capturing && !checkingPermission }
  /// Which way a touchpad swipe moves: the glasses' settings can flip it.
  var reverseSwipes: Bool {
    didSet { UserDefaults.standard.set(reverseSwipes, forKey: Self.reverseSwipesDefaultsKey) }
  }
  /// True while speech is paused because the glasses' audio disconnected (see `Speaker.heldForRoute`).
  private(set) var speechHeld = false

  // Hands-free session (capture button on the glasses)
  private(set) var sessionActive = false {
    didSet { updateActivity() }
  }
  private(set) var isStartingSession = false
  private(set) var sessionPaused = false
  private(set) var sessionPrompt = ClaudeClient.defaultPrompt
  private(set) var shutterStatus: ShutterButton.Status = .off

  var errorMessage: String?
  var showCameraPermissionPrompt = false
  var useHighResPhoto: Bool {
    didSet { UserDefaults.standard.set(useHighResPhoto, forKey: Self.highResDefaultsKey) }
  }
  /// Each glasses photo is also added to the Photos library. Off until the user turns it on
  /// (setSavePhotos), which is also when Photos access is asked for.
  private(set) var savePhotosToLibrary: Bool {
    didSet { UserDefaults.standard.set(savePhotosToLibrary, forKey: Self.savePhotosDefaultsKey) }
  }
  /// Runs the full glasses flow but skips Claude: waits, then speaks a sample answer.
  /// Free to use, and the wait outlasts iOS's background allowance when the phone is
  /// locked, so it also tests that the app stays running.
  var testMode: Bool {
    didSet { UserDefaults.standard.set(testMode, forKey: Self.testModeDefaultsKey) }
  }
  var canSolve: Bool { hasAPIKey || testMode }

  /// Claude's fast mode: the same model and care, about twice as quick to answer, at twice
  /// the price (a page costs roughly 10 to 20 cents instead of 5 to 10).
  var fastAnswers: Bool {
    didSet { UserDefaults.standard.set(fastAnswers, forKey: Self.fastAnswersDefaultsKey) }
  }

  /// What the photos are: math to copy line by line, or a chemistry multiple-choice test.
  var subject: ClaudeClient.Subject {
    didSet {
      UserDefaults.standard.set(subject.rawValue, forKey: Self.subjectDefaultsKey)
      speaker.itemWord = subject.itemWord
      // A session started with the old subject's usual prompt takes the new one's.
      if sessionPrompt == oldValue.defaultPrompt { sessionPrompt = subject.defaultPrompt }
      // A photo after switching is never a follow-up to an answer in the other subject.
      lastAnswerTime = nil
      if subject != oldValue { clearWorkspace() }
      conversation.subjectForNewEntries = subject.rawValue
      warmCache()
    }
  }

  /// What a photo (Solve button or capture button) asks for: the solution, or a check.
  var photoAction: ClaudeClient.PhotoAction {
    didSet { UserDefaults.standard.set(photoAction.rawValue, forKey: Self.photoActionDefaultsKey) }
  }

  /// Caches the current subject's system prompt ahead of the first photo (see
  /// `ClaudeClient.warmCache`).
  func warmCache() {
    guard !testMode, let apiKey = Keychain.read(Self.apiKeyAccount) else { return }
    let client = ClaudeClient(apiKey: apiKey, subject: subject, fast: fastAnswers)
    Task.detached { await client.warmCache() }
  }

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

    /// Its name in the Settings row.
    var shortName: String {
      switch self {
      case .azure: "Azure"
      case .heart: "Heart"
      case .apple: "Apple"
      }
    }
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

  /// Set the moment a solve is requested (before any await), and until it's done, so the
  /// Solve button can't start a second one. A capture press while busy replaces it instead
  /// (see `startSolve`).
  private(set) var solveInFlight = false
  /// True while the Solve button is checking camera permission, before the solve starts.
  private var checkingPermission = false
  /// For math, a solve stops being busy once its answer is spoken: the rest of the reply
  /// (explanation, work) keeps arriving while the next photo can already be taken.
  var isBusy: Bool { phase != .idle || checkingPermission || (subject == .chemistry && solveInFlight) }
  var isRegistered: Bool { registrationState == .registered }

  var statusText: String {
    switch phase {
    case .capturing: return "Taking a photo with your glasses…"
    case .thinking: return "Claude is working it out…"
    case .idle:
      if sessionActive {
        return sessionPaused
          ? "Session paused. Tap the glasses' touchpad once to resume."
          : "Session active. Look at the problem and press the capture button."
      }
      if !canSolve { return "Add your Anthropic API key in Settings, or turn on Test mode." }
      if !isRegistered { return "Connect your glasses to get started." }
      if !hasActiveDevice { return "Put on your glasses (hinges open)." }
      return subject == .math ? "Ready. Look at the problem and tap Solve." : "Ready. Look at the page and tap \(photoAction.name)."
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
  /// Smallest (phone clock − glasses clock) seen, i.e. the fastest delivery so far. A press
  /// whose offset is well above it waited somewhere, likely while iOS had the app suspended.
  @ObservationIgnored private var pressOffsetBaselineMs: Int64?
  @ObservationIgnored private var lastSeenPressTimestampMs: Int64?
  @ObservationIgnored private var lastLateNotice: Date?
  private static let latePressThresholdMs: Int64 = 5000
  /// The solve running now, if any. Every solve goes through `startSolve`, so a new one
  /// first stops this one and waits for it to finish: there's never more than one.
  @ObservationIgnored private var solveTask: Task<Void, Never>?
  /// Bumped by each `startSolve`, so a replaced solve that was still waiting doesn't run.
  @ObservationIgnored private var solveGeneration = 0
  /// Identifies the run whose answer is being spoken; pieces from a stopped run are dropped.
  @ObservationIgnored private var currentRunID = UUID()
  /// The answer text received so far in the current run.
  @ObservationIgnored private var receivedText = ""
  /// When each stage of the current photo happened, from the press to the first words heard.
  @ObservationIgnored private var timing = SolveTiming()
  /// When the capture press that started the next solve reached the app.
  @ObservationIgnored private var pressedAt: Date?
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
    self.savePhotosToLibrary = UserDefaults.standard.bool(forKey: Self.savePhotosDefaultsKey)
    self.testMode = UserDefaults.standard.bool(forKey: Self.testModeDefaultsKey)
    self.fastAnswers = UserDefaults.standard.object(forKey: Self.fastAnswersDefaultsKey) as? Bool ?? true
    self.subject = UserDefaults.standard.string(forKey: Self.subjectDefaultsKey).flatMap(ClaudeClient.Subject.init)
      ?? .math
    // A photo is always a solve unless a check is asked for (the glasses' double press, or
    // Check Sheet), so a check left on from before never turns a press into a check.
    self.photoAction = .solve
    let savedRate = UserDefaults.standard.object(forKey: Self.speechRateDefaultsKey) as? Float
    self.speechRate = savedRate.map { min(max($0, Speaker.rateRange.lowerBound), Speaker.rateRange.upperBound) }
      ?? Speaker.defaultRate
    let savedWritingTime = UserDefaults.standard.object(forKey: Self.writingTimeDefaultsKey) as? Double
    self.writingTime = savedWritingTime.map {
      min(max($0, Speaker.writingTimeRange.lowerBound), Speaker.writingTimeRange.upperBound)
    } ?? 1
    self.voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey)
    self.reverseSwipes = UserDefaults.standard.bool(forKey: Self.reverseSwipesDefaultsKey)
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
    speaker.itemWord = subject.itemWord
    speaker.onHoldChanged = { [weak self] held in self?.speechHeld = held }
    speaker.onIdle = { [weak self] in self?.updateActivity() }
    speaker.onAnswerAudio = { [weak self] in self?.firstWordsHeard() }
    conversation.subjectForNewEntries = subject.rawValue
    speaker.onLineStarted = { [weak self] problem, line in
      self?.linePosition = LinePosition(problem: problem, line: line)
    }
    applyVoiceEngine()
    warmCache()
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

  /// Records what the app is in the middle of, so if iOS ends it or it crashes, the next
  /// launch's log says so (see `DiagnosticsLog.reportPreviousRun`).
  private func updateActivity() {
    let activity: String? =
      switch phase {
      case .capturing: "taking a photo"
      case .thinking: "answering a photo"
      case .idle:
        speaker.isActive
          ? "speaking" : sessionActive ? "in a hands-free session, waiting for a capture press" : nil
      }
    DiagnosticsLog.setActivity(activity)
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
    guard canStartPhoto else { return }
    checkingPermission = true
    defer { checkingPermission = false }
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
        checkingPermission = false
        await startSolve(reason: "Solve tapped").value
      } else {
        // Requesting permission jumps to the Meta AI app, so confirm first.
        showCameraPermissionPrompt = true
      }
    } catch {
      errorMessage = ErrorDetail.alertText(error)
    }
  }

  /// For the screenshot tests: puts the screens in a given state with no glasses, Claude or
  /// key involved.
  func showForScreenshots(
    registered: Bool, registering: Bool = false, glassesAwake: Bool = true, session: Bool = false,
    paused: Bool = false, starting: Bool = false, apiKey: Bool = true, phase: Phase = .idle, subject: ClaudeClient.Subject = .math,
    workspace: MathWorkspace? = nil, photo: UIImage? = nil, lastAnswer: String = ""
  ) {
    registrationState = registered ? .registered : registering ? .registering : .available
    hasActiveDevice = glassesAwake
    hasAPIKey = apiKey
    sessionActive = session
    sessionPaused = paused
    isStartingSession = starting
    self.phase = phase
    shutterStatus = session ? .active : .off
    self.subject = subject
    self.workspace = workspace
    lastPhoto = photo
    self.lastAnswer = lastAnswer
    if workspace != nil { showWorkspace() }
  }

  /// Chemistry's Check Sheet: one photo of a filled-in answer sheet, checked.
  func checkAnswerSheet() async {
    photoAction = .check
    await solve()
    photoAction = .solve
  }

  func confirmCameraPermission() async {
    showCameraPermissionPrompt = false
    let pendingPrompt = pendingSessionPrompt
    pendingSessionPrompt = nil
    if pendingPrompt == nil {
      guard !isBusy else { return }
      checkingPermission = true
    }
    defer { if pendingPrompt == nil { checkingPermission = false } }
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
        checkingPermission = false
        await startSolve(reason: "camera permission granted").value
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
    if subject == .math {
      repeatLastSpoken()
      return
    }
    guard !lastAnswer.isEmpty else { return }
    shownAnswer = lastAnswer
    speaker.speak(lastAnswer, isAnswer: true)
  }

  func stopSpeaking() {
    speaker.stop("Stop was tapped")
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
    shownAnswer = subjectSample
    speaker.speak(subjectSample)
  }

  /// The limit definition worked in full, to practice copying a long answer.
  func testLimitDefinition() {
    shownAnswer = Self.limitSampleAnswer
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
  /// Made once per voice list rather than on every redraw of Settings (there can be over a
  /// thousand voices).
  var availableVoices: [(id: String, label: String)] {
    let voices = Speaker.availableVoices()
    if let voiceLabels, voiceLabels.count == voices.count { return voiceLabels }
    let labels = voices.map { voice in
      let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
      let source = Speaker.isFromOtherApp(voice) ? " · other app" : ""
      return (id: voice.identifier, label: "\(voice.name) · \(Speaker.qualityName(voice.quality)) · \(region)\(source)")
    }
    voiceLabels = labels
    return labels
  }
  @ObservationIgnored private var voiceLabels: [(id: String, label: String)]?

  /// Writes every voice iOS reports to the diagnostics log, so a voice that doesn't show
  /// up in the picker can be traced (is iOS giving it to apps at all, and how is it labeled).
  func logInstalledVoices() {
    // Once per launch, and a summary: listing every voice (over a thousand on some phones)
    // each time Settings opened made the app stutter and pushed everything else out of the log.
    guard !loggedVoices else { return }
    loggedVoices = true
    let all = AVSpeechSynthesisVoice.speechVoices()
    let others = all.filter(Speaker.isFromOtherApp)
    let otherApps = Set(others.map { $0.identifier.split(separator: ".").prefix(3).joined(separator: ".") })
    diag(
      "voices",
      "iOS reports \(all.count) voices, \(others.count) from other apps (\(otherApps.sorted().joined(separator: ", ")))")
    let best = all.filter { !Speaker.isFromOtherApp($0) && Speaker.isPhoneLanguage($0.language) && $0.quality != .default }
    for voice in best {
      diag("voices", "\(voice.name) | \(voice.language) | \(Speaker.qualityName(voice.quality)) | \(voice.identifier)")
    }
  }
  @ObservationIgnored private var loggedVoices = false

  /// Says one sentence in the current voice and speed.
  func previewVoice() {
    // A real piece of an answer, with its pauses, rather than a sentence of ordinary speech.
    speaker.speak(
      subject == .chemistry
        ? "Problem: 7\nAnswer: B, as in boy. Krypton core, 5 ess 2, 4 dee 10, 5 pee 5."
        : "Write: cosine of, open parenthesis, 3 x squared, close parenthesis, times secant squared x")
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
    // A math answer is filed with its written work, which is for reading, not dictating.
    if entry.subject == ClaudeClient.Subject.math.rawValue, let spoken = Self.spokenMathResult(answer) {
      speaker.speak(spoken, isAnswer: true)
      return
    }
    shownAnswer = answer
    speaker.speak(answer)
  }

  /// What a filed math answer says aloud: "Problem 4. x equals 4." (or a check's result).
  static func spokenMathResult(_ summary: String) -> String? {
    let lines = summary.components(separatedBy: "\n")
    func value(_ prefix: String) -> String? {
      lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    let name = Speaker.problemLabel(in: lines.first ?? "").map { Speaker.itemName($0, itemWord: "Problem") + ". " } ?? ""
    return (value("The answer: ") ?? value("Check: ")).map { name + $0 }
  }

  /// A chemistry photo: the whole page answered in one request and spoken as it arrives.
  /// `action` overrides the phone's Solve / Check picker (a double press checks).
  private func run(action override: ClaudeClient.PhotoAction? = nil) async {
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
    let runID = UUID()
    currentRunID = runID
    receivedText = ""
    timing = SolveTiming(start: pressedAt ?? .now, pressed: pressedAt != nil)
    pressedAt = nil
    // Where the last answer was, if this photo cut it short (or Stop did), before stopping it.
    // Kept until a new answer arrives, so a photo that fails doesn't lose it.
    if let progress = speaker.progress { lastAnswerStoppedAt = progress }
    let stoppedAt = lastAnswerStoppedAt
    speaker.stop("a new photo was taken")
    // Silent audio from the start, not just while Claude works: with the phone locked, a
    // press gives the app about 30 seconds, and the photo plus a reconnect can take longer.
    speaker.beginKeepAlive()
    defer {
      phase = .idle
      backgroundActivity.end()
    }
    let action = override ?? photoAction
    let prompt =
      action == .check ? ClaudeClient.PhotoAction.checkPrompt : sessionActive ? sessionPrompt : subject.defaultPrompt
    // Captured now, so an answer that arrives after the session ends still files under it.
    let chatSessionID = conversation.currentSessionID
    diag("solve", "start (app \(Self.appStateDescription), hands-free \(sessionActive), test mode \(testMode))")

    let photo: Data
    do {
      phase = .capturing
      // The written answer waits for the new one rather than showing the last as if it were it.
      shownAnswer = ""
      linePosition = nil
      // A refresh started after the previous photo must finish before this one.
      if let refresh = sessionRefreshTask {
        await refresh.value
        timing.mark("waited for the glasses to reconnect")
      }
      photo = try await captureWithRecovery()
      timing.mark("photo taken")
      try Task.checkCancellation()
      diag("solve", "photo received, \(photo.count) bytes; calling Claude")
    } catch where Task.isCancelled {
      diag("solve", "the photo was stopped for a newer one")
      return
    } catch {
      phase = .idle
      scheduleShutterRevive("after a failed photo", force: true)
      shownAnswer = lastAnswer
      reportSolveFailure(error)
      conversation.add(
        prompt: prompt, photo: nil, answer: nil, error: error.localizedDescription, isTest: testMode,
        sessionID: chatSessionID)
      speaker.endKeepAliveAfterSpeech()
      return
    }
    lastPhoto = UIImage(data: photo)
    saveToPhotos(photo)
    phase = .thinking
    // In SDK 1.0.0 a second camera stream in the same session can fail at once (Meta, SDK
    // issue #260), so each photo gets a fresh session. Refresh now, while Claude works and
    // the button can't be used anyway; this also re-adds the button events a photo can drop.
    if sessionActive {
      startSessionRefresh(reason: "fresh camera for the next photo")
    } else {
      camera.endSession()
    }

    // Claude can take longer than iOS's background allowance. Playing (silent) audio (started
    // above) keeps the app running until the spoken answer, which keeps it running to the end.
    answerStarted = false
    speaker.speak("Got it. Working on it.")
    // Claude can think for a minute before the first words, or pause partway; say so now and
    // then, so the silence doesn't sound like the app stopped.
    let waitingCue = Task { [weak self] in
      while true {
        try? await Task.sleep(for: Self.stillWorkingInterval)
        guard !Task.isCancelled, let self else { return }
        if !self.answerStarted {
          self.speaker.announce("Still working.", ifBusy: .skip)
        } else if self.speaker.sayWhileWaiting("Still working.") {
          diag("solve", "the answer paused while Claude was still writing; said \"Still working.\"")
        }
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
        let stopNote = previous == nil ? nil : stoppedAt.map { Self.describeStop($0) }
        if previous != nil { diag("solve", "sending as a follow-up to the last answer. \(stopNote ?? "It was heard to the end.")") }
        reply = try await ClaudeClient(apiKey: apiKey, subject: subject, fast: fastAnswers).solve(
          photo: photo, prompt: prompt, previousAnswer: previous, stoppedAt: stopNote, action: action,
          onText: { [weak self] piece in self?.answerArrived(piece, runID: runID) },
          onRestartLine: { [weak self] in self?.speaker.discardUnfinishedLine() })
      } else {
        let text = try await simulatedAnswer(photo: photo)
        answerArrived(text, runID: runID)
        reply = ClaudeClient.Answer(text: text, stopReason: "end_turn")
      }
      try Task.checkCancellation()
      // An answer that ended early says so, and where, rather than sounding complete.
      let cutOff: Speaker.CutOff? =
        switch reply.stopReason {
        case "end_turn", "stop_sequence": nil
        case "max_tokens", "model_context_window_exceeded": .ranOut
        case nil: .dropped
        default: .stopped
        }
      let notice = cutOff.map { Speaker.cutOffNotice($0, answer: reply.text, itemWord: subject.itemWord) }
      speaker.finishAnswer(notice: notice)
      let answer = [reply.text.trimmingCharacters(in: .whitespacesAndNewlines), notice]
        .compactMap { $0 }.joined(separator: "\n")
      lastAnswer = answer
      shownAnswer = answer
      replayIndex = nil
      lastAnswerStoppedAt = nil
      // A Test mode sample isn't a real answer, so it's never sent as one to follow up on.
      lastAnswerTime = testMode ? nil : .now
      diag(
        "solve",
        "answer received, \(reply.text.count) characters, ended by \(reply.stopReason ?? "a dropped connection") "
          + "(app \(Self.appStateDescription))")
      conversation.add(
        prompt: prompt, photo: photo, answer: answer, error: nil, isTest: testMode, sessionID: chatSessionID)
    } catch where Task.isCancelled {
      stoppedForNewPhoto(prompt: prompt, photo: photo, sessionID: chatSessionID)
      return
    } catch {
      reportSolveFailure(error)
      conversation.add(
        prompt: prompt, photo: photo, answer: nil, error: error.localizedDescription, isTest: testMode,
        sessionID: chatSessionID)
    }
    speaker.endKeepAliveAfterSpeech()
  }

  /// Starts answering a new photo. One already in progress (taking its photo, waiting for
  /// Claude, or receiving the answer) is stopped first, silently and at once, and the new one
  /// starts when it has finished cleaning up. Its place in the answer is kept, so the new
  /// photo goes to Claude as a follow-up that says how far the listener got.
  @discardableResult
  private func startSolve(reason: String, action: ClaudeClient.PhotoAction? = nil) -> Task<Void, Never> {
    let previous = solveTask
    if let previous {
      diag("solve", "\(reason) while still working on the last photo: stopping that answer to answer the new photo")
      previous.cancel()
      speaker.stop("a new photo was taken")
    }
    // Latest capture wins: the photo before this one stops counting now, not when the new photo
    // arrives, so nothing from it can be shown, said or filed, even if its answer comes later.
    if subject == .math { displaceWorkspace() }
    lastPhoto = nil
    phase = .capturing
    photosStarted += 1
    solveInFlight = true
    solveGeneration += 1
    let generation = solveGeneration
    let task = Task { [weak self] in
      await previous?.value
      guard let self, self.solveGeneration == generation, !Task.isCancelled else { return }
      if self.subject == .math { await self.runMath() } else { await self.run(action: action) }
      if self.solveGeneration == generation {
        self.solveInFlight = false
        self.solveTask = nil
        if self.phase == .capturing { self.phase = .idle }
      }
    }
    solveTask = task
    return task
  }

  /// A run stopped for a newer photo: files what arrived, and keeps it as the answer to
  /// follow up on if any of it was heard (the next run reads where from `speaker.progress`).
  private func stoppedForNewPhoto(prompt: String, photo: Data, sessionID: UUID?) {
    let text = receivedText.trimmingCharacters(in: .whitespacesAndNewlines)
    diag("solve", "stopped for a newer photo, \(text.count) characters into the answer")
    if !text.isEmpty, speaker.progress != nil {
      lastAnswer = text
      lastAnswerStoppedAt = nil
      lastAnswerTime = testMode ? nil : .now
    }
    conversation.add(
      prompt: prompt, photo: photo, answer: text.isEmpty ? nil : text + "\n(Stopped for a new photo.)",
      error: text.isEmpty ? "Stopped for a new photo." : nil, isTest: testMode, sessionID: sessionID)
  }

  /// The answer's first words are playing: logs how long each stage took.
  private func firstWordsHeard() {
    guard !timing.finished else { return }
    timing.mark("first words heard")
    timing.finished = true
    diag("timing", timing.summary)
  }

  /// Tells Claude how much of its last answer was heard before a new photo cut it short. A
  /// multiple-choice question's one line is its answer (the chemistry prompt says so).
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

  /// Speaks the next piece of an answer, starting the answer with the first piece. Pieces
  /// from a run that was stopped for a newer photo are dropped.
  private func answerArrived(_ piece: String, runID: UUID) {
    guard runID == currentRunID, !Task.isCancelled else { return }
    receivedText += piece
    if !answerStarted {
      shownAnswer = ""
      linePosition = nil
    }
    shownAnswer += piece
    if !answerStarted {
      answerStarted = true
      timing.mark("Claude's first words arrived")
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

  /// Test mode's wait with the app in the foreground. A variable so tests can lengthen it.
  static var testModeWait: Duration = .seconds(2)

  /// Test mode's stand-in for Claude. Locked, it waits longer than iOS's ~30-second
  /// background allowance, so hearing the answer means the keep-alive worked.
  private func simulatedAnswer(photo: Data) async throws -> String {
    let inBackground = UIApplication.shared.applicationState != .active
    let wait: Duration = inBackground ? .seconds(35) : Self.testModeWait
    diag("solve", "test mode: waiting \(wait) instead of calling Claude (app \(Self.appStateDescription))")
    try await Task.sleep(for: wait)
    diag("solve", "test mode: wait finished (app \(Self.appStateDescription))")
    let kilobytes = photo.count / 1024
    return "Test mode. The photo arrived, \(kilobytes) kilobytes"
      + (inBackground ? ", and the app stayed running with the phone locked. " : ". ")
      + subjectSample
  }

  /// Turns Save Photos to Photos on or off. Turning it on asks for add-only Photos access (the
  /// app can add photos but never see the library); without it the setting stays off.
  func setSavePhotos(_ on: Bool) async {
    guard on else {
      savePhotosToLibrary = false
      return
    }
    let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    diag("photos", "add-only access: \(access.rawValue)")
    if access == .authorized || access == .limited {
      savePhotosToLibrary = true
    } else {
      savePhotosToLibrary = false
      errorMessage = "Glasses Solver can't add to Photos. Allow it in Settings > Privacy & Security > Photos."
    }
  }

  /// For the tests: receives the photos that would be added to Photos.
  static var photoSaveOverride: ((Data) -> Void)?

  /// Adds a glasses photo to Photos when that's on: the photo exactly as the glasses sent it.
  /// Called once per photo the glasses took, right after the capture succeeded (a failed try
  /// and its retry are one capture: only the photo that arrived is added). It runs on its own,
  /// so a failure here never stops a solve.
  func saveToPhotos(_ photo: Data) {
    guard savePhotosToLibrary else { return }
    if let save = Self.photoSaveOverride {
      save(photo)
      return
    }
    let access = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard access == .authorized || access == .limited else {
      diag("photos", "not added to Photos: access is \(access.rawValue)")
      return
    }
    Task {
      do {
        try await Self.addToPhotos(photo)
        diag("photos", "added the photo to Photos")
      } catch {
        diag("photos", "adding to Photos FAILED: \(ErrorDetail.describe(error))")
      }
    }
  }

  /// PhotoKit runs the change block on its own queue, so it must not be main-actor code:
  /// Swift 6 stops the app when a main-actor closure runs anywhere else.
  nonisolated private static func addToPhotos(_ photo: Data) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photo, options: nil)
    }
  }

  /// Takes the photo; if the camera fails in a way a fresh glasses session fixes, starts one
  /// and tries once more.
  private func captureWithRecovery() async throws -> Data {
    do {
      return try await camera.capturePhoto(highResolution: useHighResPhoto, keepSession: sessionActive)
    } catch let error as GlassesError where error.isFixedByFreshSession {
      // The retry is always a normal photo: the high-resolution still is experimental, and on
      // the user's glasses it failed every time ("Capture failed") while the normal one works.
      diag(
        "solve",
        "photo failed (\(ErrorDetail.describe(error))); retrying once with a fresh glasses session"
          + (useHighResPhoto ? " and a normal-resolution photo" : ""))
      if sessionActive {
        try await refreshHandsFreeSession(reason: "photo failed")
      } else {
        camera.endSession()
      }
      return try await camera.capturePhoto(highResolution: false, keepSession: sessionActive)
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

  // MARK: - Math: answer first, then Explain, Check and swipes

  /// Requests running for problems after the first, by label.
  @ObservationIgnored private var mathTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  @ObservationIgnored private var explainTask: Task<Void, Never>?
  /// The workspace a check or explanation request belongs to, so a stale one can't clear a
  /// newer one's state.
  @ObservationIgnored private var checkWorkspaceID: UUID?
  @ObservationIgnored private var explainWorkspaceID: UUID?
  /// A problem whose explanation was asked for before it arrived; it's said when it does.
  @ObservationIgnored private var pendingExplain: String?
  /// Problems whose answer has been said since they became the current one.
  @ObservationIgnored private var announced: Set<String> = []
  /// Problems whose name was said on a swipe before their answer was ready, so the answer
  /// doesn't repeat it.
  @ObservationIgnored private var introduced: Set<String> = []
  /// The last answer, explanation or check result said, for Repeat. Status words aren't kept.
  @ObservationIgnored private var lastSpoken: String?
  /// Math requests running (photo, problems, checks, explanations). While any is, silent
  /// audio keeps the app running with the phone locked.
  @ObservationIgnored private var mathWork = 0

  private func beginMathWork() {
    if mathWork == 0 { speaker.beginKeepAlive() }
    mathWork += 1
  }

  private func endMathWork() {
    mathWork = max(mathWork - 1, 0)
    if mathWork == 0 { speaker.endKeepAliveAfterSpeech() }
  }

  /// A math photo: taken, then its first problem solved, with the answer said the moment it
  /// arrives. The rest of the reply (explanation, written work) keeps arriving after that, and
  /// the next problem is prepared in the background.
  private func runMath() async {
    guard Keychain.read(Self.apiKeyAccount) != nil || testMode else {
      hasAPIKey = false
      return
    }
    // A press may wake the app in the background, with about 30 seconds to run. If that runs
    // out mid-photo, stop the camera rather than be suspended with a stream running (#231).
    let backgroundActivity = BackgroundActivity(name: "Solve") { [weak self] in
      self?.camera.abortCapture()
    }
    defer { backgroundActivity.end() }
    timing = SolveTiming(start: pressedAt ?? .now, pressed: pressedAt != nil)
    pressedAt = nil
    cancelMathWork()
    speaker.stop("a new photo was taken")
    beginMathWork()
    defer { endMathWork() }
    let chatSessionID = conversation.currentSessionID
    diag("solve", "math photo (app \(Self.appStateDescription), hands-free \(sessionActive), test mode \(testMode))")

    let photo: Data
    do {
      phase = .capturing
      // A refresh started after the previous photo must finish before this one.
      if let refresh = sessionRefreshTask {
        await refresh.value
        timing.mark("waited for the glasses to reconnect")
      }
      photo = try await captureWithRecovery()
      timing.mark("photo taken")
      try Task.checkCancellation()
    } catch where Task.isCancelled {
      phase = .idle
      diag("solve", "the photo was dropped (a double press asked for Check, or a newer photo came)")
      if sessionActive { startSessionRefresh(reason: "fresh camera for the next photo") } else { camera.endSession() }
      return
    } catch {
      phase = .idle
      scheduleShutterRevive("after a failed photo", force: true)
      diag("solve", "FAILED: \(ErrorDetail.describe(error))")
      diag("solve", "OUTCOME photo-capture-failed: \(ErrorDetail.describe(error))")
      errorMessage = ErrorDetail.alertText(error)
      say("Couldn't take the photo. Capture again.", meaningful: false)
      conversation.add(
        prompt: "Solve", photo: nil, answer: nil, error: error.localizedDescription, isTest: testMode,
        sessionID: chatSessionID)
      return
    }
    lastPhoto = UIImage(data: photo)
    saveToPhotos(photo)
    // A fresh glasses session for the next photo (SDK issue #260), while Claude works.
    if sessionActive { startSessionRefresh(reason: "fresh camera for the next photo") } else { camera.endSession() }
    guard let jpeg = ClaudeClient.preparedJPEG(from: photo) else {
      phase = .idle
      diag("solve", "OUTCOME photo-prepare-failed: the photo (\(photo.count) bytes) couldn't be made into a JPEG to send")
      say("Couldn't use that photo. Capture again.", meaningful: false)
      conversation.add(
        prompt: "Solve", photo: nil, answer: nil, error: "The photo couldn't be prepared to send [photo-prepare-failed]",
        isTest: testMode, sessionID: chatSessionID)
      return
    }
    let space = MathWorkspace(photo: photo, jpeg: jpeg)
    workspace = space
    displacedWorkspace = nil
    showWorkspace()
    phase = .thinking
    let cue = stillWorkingCue()
    defer { cue.cancel() }
    await prepare(nil, in: space.id, sessionID: chatSessionID)
    if phase == .thinking { phase = .idle }
  }

  /// "Still working." once a wait passes 20 seconds, then every 40, until the answer comes.
  private func stillWorkingCue() -> Task<Void, Never> {
    Task { [weak self] in
      var wait = Self.stillWorkingInterval
      while true {
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled, let self, self.phase == .thinking else { return }
        self.speaker.announce("Still working.", ifBusy: .skip)
        wait = .seconds(40)
      }
    }
  }

  /// Streams one problem's reply into the workspace. `label` nil is a photo's first request,
  /// which also lists the photo's problems; otherwise it's that problem.
  private func prepare(_ label: String?, in id: UUID, sessionID: UUID?) async {
    guard let space = workspace, space.id == id else { return }
    let buffer = ReplyBuffer()
    let ask = label.map(ClaudeClient.problemAsk) ?? ClaudeClient.solveAsk
    do {
      let reply = try await askClaude(
        .photo(jpeg: space.jpeg, ask: ask), simulated: Self.simulatedMathReply(label: label),
        onText: { [weak self] piece in
          guard !Task.isCancelled else { return }
          buffer.text += piece
          self?.apply(MathReply.parse(buffer.text, complete: false), asked: label, in: id, final: false)
        },
        onRestartLine: { buffer.text = ClaudeClient.completeLines(buffer.text) })
      try Task.checkCancellation()
      let parsed = Self.finalReply(reply)
      apply(parsed, asked: label, in: id, final: true)
      finished(parsed, text: reply.text, asked: label, in: id, stopReason: reply.stopReason, sessionID: sessionID)
    } catch where Task.isCancelled {
      diag("solve", "math request stopped (a newer photo, or the subject changed)")
    } catch {
      failed(error, asked: label, in: id, sessionID: sessionID)
    }
  }

  /// Stores what a reply says so far. Says the answer the moment it's complete (the next tag
  /// has started, or the reply ended), if it's the problem being looked at, and an
  /// explanation that was asked for early.
  private func apply(_ reply: MathReply, asked: String?, in id: UUID, final: Bool) {
    guard var space = workspace, space.id == id else { return }
    if asked == nil {
      if space.labels.isEmpty, !reply.labels.isEmpty { space.labels = reply.labels }
      if let unclear = reply.unclear { space.unclear = unclear }
    }
    guard let label = asked ?? reply.label else {
      workspace = space
      return
    }
    if !space.labels.contains(label) { space.labels.append(label) }
    // The first reply decides which problem is current: the one it solved.
    if asked == nil, space.problems[label] == nil, let at = space.labels.firstIndex(of: label) { space.index = at }
    var problem = space.problems[label] ?? MathProblem()
    if !reply.question.isEmpty { problem.question = reply.question }
    if let answer = reply.answerIfComplete { problem.answer = answer }
    if let explanation = reply.explanationIfComplete { problem.explanation = explanation }
    if !reply.work.isEmpty { problem.work = reply.work }
    problem.ownWork = reply.ownWork
    if final { problem.status = problem.answer.isEmpty ? .failed : .ready }
    space.problems[label] = problem
    workspace = space
    showWorkspace()
    guard space.currentLabel == label else { return }
    if !problem.answer.isEmpty, !announced.contains(label) {
      announced.insert(label)
      if phase == .thinking {
        phase = .idle
        timing.mark("answer arrived")
      }
      let named = space.labels.count > 1 && !introduced.contains(label)
      introduced.remove(label)
      say((named ? "\(Speaker.itemName(label, itemWord: "Problem")). " : "") + problem.answer)
    }
    if pendingExplain == label, !problem.explanation.isEmpty {
      pendingExplain = nil
      say(problem.explanation, after: true)
    }
  }

  /// A reply is complete: files it, says what went wrong if there's no answer, and starts on
  /// the next problem so a swipe finds it ready.
  private func finished(
    _ reply: MathReply, text: String, asked: String?, in id: UUID, stopReason: String?, sessionID: UUID?
  ) {
    guard let space = workspace, space.id == id else { return }
    if phase == .thinking { phase = .idle }
    let label = asked ?? reply.label
    guard let label, let problem = space.problems[label], !problem.answer.isEmpty else {
      let failure = reply.failure(asked: asked) ?? .noAnswer
      Self.logUnusable(failure.rawValue, reply: reply, text: text, stopReason: stopReason, request: asked)
      if asked == nil {
        let why = Self.spokenFailure(failure, unclear: reply.unclear)
        say(why + " Capture again.", meaningful: false)
        conversation.add(
          prompt: "Solve", photo: space.photo, answer: nil, error: "\(why) [\(failure.rawValue)]", isTest: testMode,
          sessionID: sessionID)
      } else if space.currentLabel == asked {
        say("Couldn't solve \(Speaker.itemName(label ?? "", itemWord: "problem")). Swipe back to it to try again.", meaningful: false)
      }
      return
    }
    if stopReason != "end_turn" && stopReason != "stop_sequence" {
      diag("solve", "problem \(label)'s reply ended early (\(stopReason ?? "dropped connection")); keeping what came")
    }
    diag(
      "solve",
      "OUTCOME answered: problem \(label), \(problem.answer.count)-character answer, explanation "
        + (problem.explanation.isEmpty ? "missing" : "present") + ", \(problem.work.count) work lines; tags: "
        + reply.tagsSeen.joined(separator: ", "))
    conversation.add(
      prompt: "Problem \(label)", photo: space.photo, answer: problem.summary(label: label), error: nil,
      isTest: testMode, sessionID: sessionID, title: problem.question)
    // Explain was pressed, but this reply had no explanation (it was cut off): ask for one.
    if pendingExplain == label, problem.explanation.isEmpty {
      pendingExplain = nil
      explainCurrentProblem()
    }
    if let at = space.labels.firstIndex(of: label), at == space.index, space.labels.indices.contains(at + 1) {
      ensurePrepared(space.labels[at + 1])
    }
  }

  /// A request failed. An answer already said is kept (only the rest is missing); otherwise
  /// the problem is marked so a later swipe or press tries again.
  private func failed(_ error: Error, asked: String?, in id: UUID, sessionID: UUID?) {
    diag("solve", "math request FAILED: \(ErrorDetail.describe(error))")
    diag("solve", "OUTCOME \(Self.requestFailureKind(error)): " + (asked.map { "problem " + $0 } ?? "the photo's first request"))
    guard var space = workspace, space.id == id else { return }
    let wasWaiting = phase == .thinking
    if wasWaiting { phase = .idle }
    for (label, problem) in space.problems where problem.status == .preparing && (asked == nil || asked == label) {
      space.problems[label]?.status = problem.answer.isEmpty ? .failed : .ready
    }
    workspace = space
    showWorkspace()
    if asked == nil, wasWaiting {
      errorMessage = ErrorDetail.alertText(error)
      say(Self.withoutFinalStop(error.localizedDescription) + ". Capture again.", meaningful: false)
      conversation.add(
        prompt: "Solve", photo: space.photo, answer: nil, error: error.localizedDescription, isTest: testMode,
        sessionID: sessionID)
    } else if let asked, space.currentLabel == asked, space.problems[asked]?.answer.isEmpty ?? true {
      say("Couldn't solve \(Speaker.itemName(asked, itemWord: "problem")). Swipe back to it to try again.", meaningful: false)
    }
  }

  /// Starts solving a problem from the current photo, unless it's ready or already underway.
  private func ensurePrepared(_ label: String) {
    guard var space = workspace, mathTasks[label] == nil else { return }
    if let problem = space.problems[label], problem.status != .failed { return }
    space.problems[label] = MathProblem()
    workspace = space
    let id = space.id
    let sessionID = conversation.currentSessionID
    diag("solve", "preparing problem \(label) in the background")
    mathTasks[label] = Task { [weak self] in
      guard let self else { return }
      self.beginMathWork()
      defer { self.endMathWork() }
      await self.prepare(label, in: id, sessionID: sessionID)
      if self.workspace?.id == id { self.mathTasks[label] = nil }
    }
  }

  /// Swipe: the next or previous problem in the same photo, with no new photo. A problem
  /// that's ready is said at once; one that isn't is named and prepared.
  func moveProblem(by step: Int) {
    guard subject == .math else { return }
    guard var space = workspace, !space.labels.isEmpty else {
      say("No problem yet. Press capture first.", meaningful: false)
      return
    }
    guard space.labels.count > 1 else {
      say("This photo has one problem.", meaningful: false)
      return
    }
    let target = space.index + step
    guard space.labels.indices.contains(target) else {
      say(step > 0 ? "That's the last problem." : "That's the first problem.", meaningful: false)
      return
    }
    space.index = target
    workspace = space
    pendingExplain = nil
    showWorkspace()
    let label = space.labels[target]
    let name = Speaker.itemName(label, itemWord: "Problem") + "."
    if let problem = space.problems[label], !problem.answer.isEmpty {
      announced.insert(label)
      say(name + " " + problem.answer)
      if space.labels.indices.contains(target + 1) { ensurePrepared(space.labels[target + 1]) }
    } else {
      announced.remove(label)
      introduced.insert(label)
      say(name, meaningful: false)
      ensurePrepared(label)
    }
  }

  /// Explain: the stored explanation of the current problem. If it hasn't arrived yet it's
  /// said when it does; if the reply had none, it's asked for from the stored work, with no
  /// new photo.
  func explainCurrentProblem() {
    guard subject == .math else { return }
    guard let space = workspace, let label = space.currentLabel, let problem = space.problems[label] else {
      say(phase == .idle ? "Nothing to explain yet." : "Still working.", meaningful: false)
      return
    }
    if !problem.explanation.isEmpty {
      say(problem.explanation)
      return
    }
    if problem.status == .preparing {
      pendingExplain = label
      if problem.answer.isEmpty { say("Still working.", meaningful: false) }
      return
    }
    guard !problem.answer.isEmpty else {
      say("Nothing to explain yet.", meaningful: false)
      return
    }
    guard explainTask == nil else { return }
    let id = space.id
    explainWorkspaceID = id
    explainTask = Task { [weak self] in
      guard let self else { return }
      self.beginMathWork()
      defer {
        self.endMathWork()
        if self.explainWorkspaceID == id {
          self.explainTask = nil
          self.explainWorkspaceID = nil
        }
      }
      do {
        let reply = try await self.askClaude(
          .text(ClaudeClient.explainAsk(label: label, question: problem.question, solution: problem.solution)),
          simulated: "Explain: " + Self.simulatedExplanation)
        let parsedExplanation = Self.finalReply(reply)
        let explanation = parsedExplanation.explanationIfComplete ?? ""
        if explanation.isEmpty {
          Self.logUnusable(
            "explain-reply-no-explanation", reply: parsedExplanation, text: reply.text, stopReason: reply.stopReason,
            request: label)
        }
        guard var space = self.workspace, space.id == id, !explanation.isEmpty else { throw ClaudeError.emptyAnswer }
        space.problems[label]?.explanation = explanation
        self.workspace = space
        self.showWorkspace()
        if space.currentLabel == label { self.say(explanation) }
      } catch where Task.isCancelled {
      } catch {
        diag("solve", "explanation FAILED: \(ErrorDetail.describe(error))")
        if self.workspace?.id == id { self.say("Couldn't get an explanation. Double-tap to try again.", meaningful: false) }
      }
    }
  }

  /// Check, independently: when the photo shows the listener's own work, their lines are
  /// checked against the problem. Otherwise the problem is solved again without seeing the
  /// first answer (a model re-solving with its earlier solution in view leans toward agreeing
  /// with it), and a second request compares the two. The result is Correct, Incorrect (with
  /// the corrected answer and why) or Unclear.
  func checkCurrentProblem() {
    guard subject == .math else { return }
    guard let space = workspace, let label = space.currentLabel, let problem = space.problems[label],
      !problem.answer.isEmpty
    else {
      let working = phase != .idle || workspace?.current?.status == .preparing
      say(working ? "Still working." : "Nothing to check yet. Press capture first.", meaningful: false)
      return
    }
    if let check = problem.check {
      say(check)
      return
    }
    guard checkTask == nil else {
      say("Still checking.", meaningful: false)
      return
    }
    say("Checking.", meaningful: false)
    isChecking = true
    let id = space.id
    let jpeg = space.jpeg
    let sessionID = conversation.currentSessionID
    checkWorkspaceID = id
    checkTask = Task { [weak self] in
      guard let self else { return }
      self.beginMathWork()
      defer {
        self.endMathWork()
        if self.checkWorkspaceID == id {
          self.checkTask = nil
          self.checkWorkspaceID = nil
          self.isChecking = false
        }
      }
      let verdict: String
      do {
        if problem.ownWork {
          let reply = try await self.askClaude(
            .photo(jpeg: jpeg, ask: ClaudeClient.ownWorkAsk(label: label, reference: problem.solution)),
            simulated: "Verdict: Correct. Your work is right.")
          verdict = Self.verdict(in: reply, request: label)
        } else {
          let again = try await self.askClaude(
            .photo(jpeg: jpeg, ask: ClaudeClient.resolveAsk(label)), simulated: Self.simulatedMathReply(label: label))
          let second = Self.finalReply(again)
          if second.answerIfComplete == nil {
            Self.logUnusable(
              "check-resolve-no-answer", reply: second, text: again.text, stopReason: again.stopReason, request: label)
            verdict = "Unclear. The problem couldn't be solved a second time."
          } else {
            let secondSolution = (["Answer: \(second.answer)"] + second.work).joined(separator: "\n")
            let compared = try await self.askClaude(
              .text(
                ClaudeClient.compareAsk(
                  label: label, question: problem.question, first: problem.solution, second: secondSolution)),
              simulated: "Verdict: Correct. \(problem.answer)")
            verdict = Self.verdict(in: compared, request: label)
          }
        }
      } catch {
        if !Task.isCancelled {
          diag("solve", "check FAILED: \(ErrorDetail.describe(error))")
          if self.workspace?.id == id { self.say("Couldn't check it. Double press to try again.", meaningful: false) }
        }
        return
      }
      guard var space = self.workspace, space.id == id else { return }
      space.problems[label]?.check = verdict
      self.workspace = space
      self.showWorkspace()
      diag("solve", "check of problem \(label): \(verdict)")
      self.conversation.add(
        prompt: "Check problem \(label)", photo: nil, answer: "Problem: \(label)\nCheck: \(verdict)", error: nil,
        isTest: self.testMode, sessionID: sessionID, title: "Check · " + (problem.question.isEmpty ? "problem \(label)" : problem.question))
      if space.currentLabel == label { self.say(verdict) }
    }
  }

  /// Repeat: the last answer, explanation or check result again, with nothing recalculated.
  func repeatLastSpoken() {
    guard let lastSpoken else {
      say("Nothing to repeat yet.", meaningful: false)
      return
    }
    speaker.speak(lastSpoken, isAnswer: true)
  }

  /// Says `text`. An answer, explanation or check result is kept for Repeat and replaces what's
  /// being said; a status ("Checking.", "That's the last problem.") waits its turn. With
  /// `after`, it's said once what's playing ends.
  private func say(_ text: String, meaningful: Bool = true, after: Bool = false) {
    diag("audio", "say (\(meaningful ? "result" : "status")): \"\(text.prefix(80))\"")
    if meaningful {
      lastSpoken = text
      if after && speaker.isActive {
        speaker.announce(text, ifBusy: .after)
      } else {
        speaker.speak(text, isAnswer: true)
      }
    } else {
      speaker.announce(text, ifBusy: .after)
    }
  }

  /// A new photo was asked for: the current one is set aside (its requests stopped), so no
  /// later result from it can reach the screen, the voice or the history.
  private func displaceWorkspace() {
    cancelMathWork()
    if let space = workspace {
      diag("solve", "photo \(space.id.uuidString.prefix(8)) replaced by a new capture; its results no longer count")
      displacedWorkspace = space
    }
    workspace = nil
    shownAnswer = ""
    linePosition = nil
  }

  /// Stops everything still being worked out for the last photo.
  private func cancelMathWork() {
    mathTasks.values.forEach { $0.cancel() }
    mathTasks.removeAll()
    checkTask?.cancel()
    checkTask = nil
    checkWorkspaceID = nil
    isChecking = false
    explainTask?.cancel()
    explainTask = nil
    explainWorkspaceID = nil
    pendingExplain = nil
    announced.removeAll()
    introduced.removeAll()
  }

  /// Forgets the math photo (the subject changed).
  private func clearWorkspace() {
    cancelMathWork()
    workspace = nil
    lastSpoken = nil
    shownAnswer = ""
  }

  /// The written answer page shows every problem solved from the photo, in printed order.
  private func showWorkspace() {
    guard let space = workspace else { return }
    linePosition = nil
    shownAnswer = space.labels.compactMap { label in
      space.problems[label].flatMap { $0.answer.isEmpty ? nil : $0.written(label: label) }
    }.joined(separator: "\n")
  }

  /// A math request, to Claude or, in Test mode, a sample reply after a wait (35 seconds with
  /// the phone locked, longer than iOS's background allowance).
  private func askClaude(
    _ request: ClaudeClient.MathRequest, simulated: String,
    onText: @escaping @MainActor @Sendable (String) -> Void = { _ in },
    onRestartLine: @escaping @MainActor @Sendable () -> Void = {}
  ) async throws -> ClaudeClient.Answer {
    if testMode {
      let inBackground = UIApplication.shared.applicationState != .active
      let wait = inBackground ? .seconds(35) : Self.testModeWait
      if Self.testModeIgnoresCancellation {
        // As a real reply can: it arrives even though its photo was replaced meanwhile.
        await Task.detached { try? await Task.sleep(for: wait) }.value
      } else {
        try await Task.sleep(for: wait)
      }
      let reply = Self.simulatedReplyOverride?(request) ?? ClaudeClient.Answer(text: simulated, stopReason: "end_turn")
      onText(reply.text)
      return reply
    }
    guard let apiKey = Keychain.read(Self.apiKeyAccount) else {
      hasAPIKey = false
      throw ClaudeError.http(status: 401, message: "No API key")
    }
    return try await ClaudeClient(apiKey: apiKey, subject: subject, fast: fastAnswers).respond(
      to: request, onText: onText, onRestartLine: onRestartLine)
  }

  /// What the glasses say when a photo's first reply can't be used. An unreadable photo and a
  /// reply in the wrong format are told apart.
  static func spokenFailure(_ failure: MathReply.Failure, unclear: String?) -> String {
    switch failure {
    case .unreadable: "Couldn't read that: " + withoutFinalStop(unclear ?? "") + "."
    case .unparseable, .missingProblemLine: "Claude's reply was in the wrong format."
    case .noAnswer: "Claude didn't give an answer."
    }
  }

  /// The kind of request failure, for the log: no reply at all, a refusal, or the request
  /// itself (network, HTTP, timeout).
  static func requestFailureKind(_ error: Error) -> String {
    switch error {
    case ClaudeError.emptyAnswer: "reply-empty"
    case ClaudeError.refused: "claude-refused"
    default: "claude-request-failed"
    }
  }

  /// Logs a reply that couldn't be used: what kind of failure, how it ended, which tags it
  /// had, and how it starts, so the log tells a format problem from an unreadable photo. Only
  /// Claude's reply is logged, never the request, the photo or the key.
  private static func logUnusable(_ kind: String, reply: MathReply, text: String, stopReason: String?, request: String?) {
    let start = text.prefix(300).replacingOccurrences(of: "\n", with: " / ")
    let tags = reply.tagsSeen.isEmpty ? "none" : reply.tagsSeen.joined(separator: ", ")
    diag(
      "solve",
      "OUTCOME \(kind): " + (request.map { "problem " + $0 } ?? "the photo's first request")
        + "; \(text.count) characters, ended by " + (stopReason ?? "a dropped connection")
        + "; tags: \(tags); starts: \"\(start)\"")
  }

  /// A finished math reply. Only a reply Claude ended itself is complete: one that ran out of
  /// room, was refused, or dropped after its continuations can end partway through a line, so
  /// its last line is left out and a field it was still writing doesn't count as finished.
  static func finalReply(_ reply: ClaudeClient.Answer) -> MathReply {
    MathReply.parse(reply.text, complete: reply.stopReason == "end_turn" || reply.stopReason == "stop_sequence")
  }

  /// A check reply's spoken verdict, or "Unclear" (logged) when it has none.
  static func verdict(in reply: ClaudeClient.Answer, request: String) -> String {
    let parsed = finalReply(reply)
    guard let verdict = parsed.verdict, parsed.closed.contains("verdict") else {
      logUnusable("check-reply-no-verdict", reply: parsed, text: reply.text, stopReason: reply.stopReason, request: request)
      return "Unclear. The check didn't give a result."
    }
    return verdict
  }

  private static func withoutFinalStop(_ text: String) -> String {
    var text = text.trimmingCharacters(in: .whitespaces)
    while text.hasSuffix(".") { text.removeLast() }
    return text
  }

  /// For tests: a Test mode reply that keeps going after its request is stopped, the way a
  /// late answer from Claude can.
  static var testModeIgnoresCancellation = false
  /// For tests: the Test mode reply to give for a request, instead of the sample.
  static var simulatedReplyOverride: (@MainActor (ClaudeClient.MathRequest) -> ClaudeClient.Answer)?

  /// Test mode's math photo: two problems, so swipes, Explain and Check can all be tried
  /// without Claude.
  static func simulatedMathReply(label: String?) -> String {
    if label == "2" {
      return """
        Problem: 2
        Question: test mode sample, solve 3 x plus 7 equals 19
        Answer: x equals 4.
        Explain: Test mode. Subtract 7 from both sides to get 3 x equals 12, then divide by 3.
        Own work: no
        Work:
        Write: 3 x plus 7 equals 19 || 3x + 7 = 19
        Write: 3 x equals 12 || 3x = 12
        Write: x equals 4 || x = 4
        Mark: Draw a box around line 3.
        """
    }
    return """
      Problems: 1, 2
      Problem: 1
      Question: test mode sample, solve 2 x squared plus 7 x plus 3 equals 0
      Answer: x equals negative 1 half, or x equals negative 3.
      Explain: \(simulatedExplanation)
      Own work: no
      Work:
      Write: 2 x squared plus 7 x plus 3 equals 0 || 2x^2 + 7x + 3 = 0
      Write: 2 x plus 1, times x plus 3, equals 0 || (2x + 1)(x + 3) = 0
      Write: x equals negative 1 half, or x equals negative 3 || x = -\\frac{1}{2} \\quad\\text{or}\\quad x = -3
      Mark: Draw a box around line 3.
      """
  }

  static let simulatedExplanation =
    "Test mode. The left side factors into 2 x plus 1, times x plus 3. Each factor set to 0 gives one answer."

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

  /// Connect: the app starts holding a glasses session, so the glasses' buttons solve. Until
  /// then the glasses work with Meta AI as usual.
  func connect() async {
    await startSession(prompt: sessionPrompt)
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
    speaker.resumeForWearer()
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
    speaker.speak(subject == .math ? "Session started." : "Session started. Press the capture button to solve.")
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
        speaker.resumeForWearer()
        // Button events may have dropped while paused; a resume earns a fresh set of tries.
        shutterAttempts = 0
        scheduleShutterRevive("session resumed")
      }
    case .paused:
      sessionPaused = true
      speaker.pauseForWearer()
    case .stopped:
      // Ended from the glasses (touchpad tap-and-hold, hinges closed) or lost connection.
      sessionActive = false
      sessionStateTask = nil
      shutterReviveTask?.cancel()
      shutterReviveTask = nil
      shutter.detach(from: nil)
      resetSessionState()
      conversation.endSession()
      speaker.resumeForWearer()
      speaker.announce("Glasses session ended.", ifBusy: .after)
    case .idle, .starting, .stopping:
      break
    }
  }

  private func attachShutter(to session: DeviceSession) {
    shutterAttempts += 1
    shutter.attach(
      to: session,
      onGesture: { [weak self] gesture, timestampMs in self?.gestureArrived(gesture, at: timestampMs) },
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

  // MARK: - Glasses gestures

  /// Gestures of one kind closer together than this (by the glasses' clock) count as one.
  private static func debounceMs(for gesture: ShutterButton.Gesture) -> Int64 {
    switch gesture {
    case .capturePress, .captureDoublePress: 800
    case .captureHold: 1000
    case .touchpadDoubleTap: 600
    case .swipe: 350
    }
  }
  @ObservationIgnored private var lastGestureMs: [String: Int64] = [:]
  /// The glasses' time of the last short press, to spot a double press reported after it.
  @ObservationIgnored private var lastCapturePressMs: Int64?
  /// A double press this soon after a short press means that press was its first half.
  private static let doublePressWindowMs: Int64 = 1500

  /// Every gesture from the glasses comes through here. Physical input is noisy, so a gesture
  /// that arrived late, repeats one just handled, or comes while the session is paused does
  /// nothing: doing nothing beats doing the wrong thing. The rest goes to the subject's own
  /// controls (math: per problem; chemistry: per page).
  private func gestureArrived(_ gesture: ShutterButton.Gesture, at timestampMs: Int64) {
    let lateness = pressLateness(timestampMs)
    diag(
      "inputs",
      "\(gesture): app \(Self.appStateDescription), \(lateness) ms later than the fastest delivery, "
        + "active \(sessionActive), phase \(phase), paused \(sessionPaused), \(subject.name)")
    guard sessionActive else { return }
    if lateness > Self.latePressThresholdMs {
      // The view has likely changed since; acting on it now would surprise the wearer.
      if gesture == .capturePress, lastLateNotice.map({ Date.now.timeIntervalSince($0) > 10 }) ?? true {
        lastLateNotice = .now
        speaker.announce("That button press reached the phone late. Press again.", ifBusy: .skip)
      }
      return
    }
    let kind = if case .swipe = gesture { "swipe" } else { "\(gesture)" }
    if timestampMs > 0, let last = lastGestureMs[kind], timestampMs >= last,
      timestampMs - last < Self.debounceMs(for: gesture)
    {
      diag("inputs", "\(gesture) ignored: \(timestampMs - last) ms after the previous one")
      return
    }
    lastGestureMs[kind] = timestampMs
    guard !sessionPaused else {
      speaker.announce("The session is paused. Tap the touchpad once to resume.", ifBusy: .skip)
      return
    }
    // The glasses may report a double press as a short press, then the double press. If so,
    // the photo the short press started isn't wanted.
    var replacesPhoto = false
    if gesture == .captureDoublePress, phase == .capturing, let press = lastCapturePressMs,
      timestampMs - press < Self.doublePressWindowMs
    {
      diag("inputs", "the double press came \(timestampMs - press) ms after a short press; dropping that photo")
      replacesPhoto = true
      if subject == .math {
        solveTask?.cancel()
        if workspace == nil, let displaced = displacedWorkspace {
          workspace = displaced
          displacedWorkspace = nil
          showWorkspace()
        }
      }
    }
    if gesture == .capturePress { lastCapturePressMs = timestampMs }
    if subject == .math { mathGesture(gesture) } else { chemistryGesture(gesture, replacesPhoto: replacesPhoto) }
  }

  /// Math: press to solve, double-tap to explain, double press to check, swipe to move,
  /// hold to repeat.
  private func mathGesture(_ gesture: ShutterButton.Gesture) {
    switch gesture {
    case .capturePress: pressSolve()
    case .captureDoublePress: checkCurrentProblem()
    case .captureHold: repeatLastSpoken()
    case .touchpadDoubleTap: explainCurrentProblem()
    case .swipe(let direction): moveProblem(by: isForward(direction) ? 1 : -1)
    }
  }

  /// Chemistry: press to answer the whole page, double press to check a filled-in answer
  /// sheet, double-tap to repeat the last answer, swipe to replay a question already answered.
  private func chemistryGesture(_ gesture: ShutterButton.Gesture, replacesPhoto: Bool) {
    switch gesture {
    case .capturePress: pressSolve()
    case .captureDoublePress: pressSolve(action: .check, replacingPhoto: replacesPhoto)
    case .touchpadDoubleTap: repeatWriteLine()
    case .swipe(let direction): replayQuestion(by: isForward(direction) ? 1 : -1)
    case .captureHold: diag("inputs", "capture hold has no job in chemistry; ignored")
    }
  }

  /// Which swipe means "next". The glasses report up, down, left or right, and their own
  /// settings can flip that, so Settings can too.
  private func isForward(_ direction: ShutterButton.Gesture.Swipe) -> Bool {
    (direction == .right || direction == .down) != reverseSwipes
  }

  /// A new photo. Ignored while the last one is still being taken, or before its answer has
  /// started, so one physical press never starts two solves.
  private func pressSolve(action: ClaudeClient.PhotoAction? = nil, replacingPhoto: Bool = false) {
    // A press while Claude is working replaces that photo (latest capture wins). A press while
    // the camera is still taking one is ignored, never queued, so presses can't pile up.
    if !canStartPhoto && !replacingPhoto {
      diag("inputs", "press ignored: the camera is still taking the last photo")
      return
    }
    pressedAt = .now
    startSolve(reason: action == .check ? "capture double press" : "capture press", action: action)
  }

  // MARK: - Chemistry: replaying the page

  /// The question a swipe last replayed; nil until one does, after each new answer.
  @ObservationIgnored private var replayIndex: Int?

  /// Swipe in chemistry: says an already-answered question again, from the last answer, with
  /// no new request. Starts from the question heard last.
  func replayQuestion(by step: Int) {
    guard subject == .chemistry else { return }
    let questions = Self.questions(in: lastAnswer)
    guard !questions.isEmpty else {
      speaker.announce("Nothing to replay yet.", ifBusy: .skip)
      return
    }
    guard !solveInFlight else {
      speaker.announce("Still answering.", ifBusy: .skip)
      return
    }
    let heard = speaker.progress.flatMap { progress in questions.firstIndex { $0.label == progress.problem } }
    let from = replayIndex ?? heard ?? questions.count - 1
    let target = from + step
    guard questions.indices.contains(target) else {
      speaker.announce(step > 0 ? "That's the last question." : "That's the first question.", ifBusy: .after)
      return
    }
    replayIndex = target
    diag("audio", "replaying \(Speaker.itemName(questions[target].label, itemWord: subject.itemWord))")
    speaker.speak(questions[target].text, isAnswer: true)
  }

  /// An answer split into its questions: each "Problem:" line and the lines after it.
  static func questions(in answer: String) -> [(label: String, text: String)] {
    var questions: [(label: String, text: String)] = []
    for line in answer.components(separatedBy: "\n") {
      if let label = Speaker.problemLabel(in: Speaker.spokenPart(line)) {
        questions.append((label, line))
      } else if !questions.isEmpty, line.trimmingCharacters(in: .whitespaces) != "Done." {
        questions[questions.count - 1].text += "\n" + line
      }
    }
    return questions
  }

  private func resetSessionState() {
    sessionPaused = false
    shutterStatus = .off
    shutterAttempts = 0
    shutterProblemReported = false
    lastGestureMs.removeAll()
    lastCapturePressMs = nil
    lastSeenPressTimestampMs = nil
    pressOffsetBaselineMs = nil
    sessionPrompt = subject.defaultPrompt
  }
}

/// When each stage of answering a photo happened, for the log: each stage is logged as it
/// ends, then one line with them all once the first words are heard.
struct SolveTiming {
  private(set) var start = Date()
  /// True when `start` is the capture press, false when it's the Solve button or a retry.
  var pressed = false
  private(set) var marks: [(stage: String, at: Date)] = []
  var finished = false

  init(start: Date = .now, pressed: Bool = false) {
    self.start = start
    self.pressed = pressed
  }

  mutating func mark(_ stage: String, at time: Date = .now) {
    let previous = marks.last?.at ?? start
    marks.append((stage: stage, at: time))
    diag("timing", "\(stage): \(Self.seconds(time.timeIntervalSince(previous))) (\(Self.seconds(time.timeIntervalSince(start))) in)")
  }

  /// "press to first words 9.8 s: photo taken 2.1 s, Claude's first words arrived 7.2 s, ..."
  var summary: String {
    var previous = start
    let stages = marks.map { mark -> String in
      defer { previous = mark.at }
      return "\(mark.stage) \(Self.seconds(mark.at.timeIntervalSince(previous)))"
    }
    let total = (marks.last?.at ?? start).timeIntervalSince(start)
    return "\(pressed ? "press" : "start") to first words \(Self.seconds(total)): " + stages.joined(separator: ", ")
  }

  static func seconds(_ interval: TimeInterval) -> String {
    String(format: "%.1f s", interval)
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

/// The text of a reply as it arrives, shared with the closure that receives it.
@MainActor
final class ReplyBuffer {
  var text = ""
}
