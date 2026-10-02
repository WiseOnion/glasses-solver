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
    do {
      guard try await wearables.requestPermission(.camera) == .granted else {
        errorMessage = "Camera permission wasn't granted in the Meta AI app."
        return
      }
      await run()
    } catch {
      errorMessage = error.localizedDescription
    }
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
    speaker.stop()
    defer { phase = .idle }

    do {
      phase = .capturing
      let photo = try await camera.capturePhoto(highResolution: useHighResPhoto)
      lastPhoto = UIImage(data: photo)

      phase = .thinking
      speaker.speak("Got it. Working on it.")
      let answer = try await ClaudeClient(apiKey: apiKey).solve(photo: photo)
      lastAnswer = answer
      speaker.speak(answer)
    } catch {
      let message = error.localizedDescription
      errorMessage = message
      // The user may be looking through the glasses, not at the phone.
      speaker.speak("Sorry. \(message)")
    }
  }
}
