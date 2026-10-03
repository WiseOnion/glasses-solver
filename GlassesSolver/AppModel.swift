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
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceTask: Task<Void, Never>?

  init() {
    let wearables = Wearables.shared
    let selector = AutoDeviceSelector(wearables: wearables)
    self.wearables = wearables
    self.selector = selector
    self.camera = GlassesCamera(wearables: wearables, selector: selector)
    self.registrationState = wearables.registrationState
    self.hasAPIKey = Keychain.read(Self.apiKeyAccount) != nil
    self.useHighResPhoto = UserDefaults.standard.bool(forKey: Self.highResDefaultsKey)

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
        errorMessage = error.localizedDescription
      }
    }
  }

  func disconnectGlasses() {
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        errorMessage = error.localizedDescription
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
        errorMessage = error.localizedDescription
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
      errorMessage = error.localizedDescription
    }
  }

  func confirmCameraPermission() async {
    showCameraPermissionPrompt = false
    let pendingPrompt = pendingSessionPrompt
    pendingSessionPrompt = nil
    do {
      guard try await wearables.requestPermission(.camera) == .granted else {
        errorMessage = "Camera permission wasn't granted in the Meta AI app."
        return
      }
      if let pendingPrompt {
        await beginSession(prompt: pendingPrompt)
      } else {
        await run()
      }
    } catch {
      errorMessage = error.localizedDescription
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
    // A capture-button press may wake the app in the background; ask iOS for time to finish.
    let backgroundActivity = BackgroundActivity(name: "Solve")
    speaker.stop()
    defer {
      phase = .idle
      backgroundActivity.end()
    }
    let prompt = sessionActive ? sessionPrompt : ClaudeClient.defaultPrompt

    do {
      phase = .capturing
      let photo = try await camera.capturePhoto(highResolution: useHighResPhoto)
      lastPhoto = UIImage(data: photo)

      phase = .thinking
      speaker.speak("Got it. Working on it.")
      let answer = try await ClaudeClient(apiKey: apiKey).solve(photo: photo, prompt: prompt)
      lastAnswer = answer
      speaker.speak(answer)
    } catch {
      let message = error.localizedDescription
      errorMessage = message
      // The user may be looking through the glasses, not at the phone.
      speaker.speak("Sorry. \(message)")
    }
  }

  // MARK: - Hands-free session

  /// Starts a session that stays open (also in the background) and solves on each press
  /// of the glasses' capture button, using `prompt`.
  func startSession(prompt: String) async {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
      if try await wearables.checkPermissionStatus(.camera) == .granted {
        await beginSession(prompt: trimmed)
      } else {
        pendingSessionPrompt = trimmed
        showCameraPermissionPrompt = true
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func stopSession() {
    guard sessionActive else { return }
    sessionActive = false
    sessionStateTask?.cancel()
    sessionStateTask = nil
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
      errorMessage = error.localizedDescription
      return
    }
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
    guard sessionActive else { return }
    switch state {
    case .started:
      sessionPaused = false
      // Reattach if button events dropped while paused, unless retrying can't help.
      switch shutterStatus {
      case .off, .unavailable(_, true): attachShutter(to: session)
      case .activating, .active, .unavailable(_, false): break
      }
    case .paused:
      sessionPaused = true
    case .stopped:
      // Ended from the glasses (touchpad tap-and-hold, hinges closed) or lost connection.
      sessionActive = false
      sessionStateTask = nil
      shutter.detach(from: nil)
      resetSessionState()
      speaker.speak("Glasses session ended.")
    case .idle, .starting, .stopping:
      break
    }
  }

  private func attachShutter(to session: DeviceSession) {
    shutter.attach(
      to: session,
      onPress: { [weak self] in self?.shutterPressed() },
      onStatus: { [weak self] status in self?.shutterStatusChanged(status) }
    )
    shutterStatus = shutter.status
  }

  private func shutterStatusChanged(_ status: ShutterButton.Status) {
    shutterStatus = status
    guard case .unavailable(let reason, _) = status else { return }
    errorMessage =
      "The capture button can't trigger Solve. \(reason)\n\n"
      + "Still works: the session stays on, and the Solve button in this app uses your session prompt."
    // The wearer may not be looking at the phone.
    speaker.speak("The capture button isn't available. Use the Solve button in the app.")
  }

  private func shutterPressed() {
    guard sessionActive else { return }
    guard !isBusy else {
      speaker.speak("Still working on the last one.")
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
    sessionPrompt = ClaudeClient.defaultPrompt
  }
}

/// Keeps the app running briefly after it leaves the foreground (iOS grants about 30 seconds).
@MainActor
private final class BackgroundActivity {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      MainActor.assumeIsolated { self?.end() }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
