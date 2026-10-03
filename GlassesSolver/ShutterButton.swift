import Foundation
import MWDATCore
import MWDATInputs

/// Listens for the physical capture (shutter) button on the glasses frame, using the
/// SDK 1.0 Inputs capability (experimental). Only `.captureButton` is requested, so the
/// touchpad stays with the glasses: one tap pauses/resumes the session, tap-and-hold ends it.
@MainActor
final class ShutterButton {
  enum Status: Equatable {
    case off
    case activating
    case active
    /// `retryable` is false when trying again won't help (permission or hardware).
    case unavailable(reason: String, retryable: Bool)
  }

  private(set) var status: Status = .off
  private var inputs: Inputs?
  private var eventsTask: Task<Void, Never>?
  private let tokens = ListenerTokenBag()
  private var onPress: (() -> Void)?
  private var onStatus: ((Status) -> Void)?

  /// Attaches Inputs to a started session. Presses arrive on `onPress`; activation
  /// progress and failures arrive on `onStatus`.
  func attach(
    to session: DeviceSession,
    onPress: @escaping () -> Void,
    onStatus: @escaping (Status) -> Void
  ) {
    detach(from: session)
    self.onPress = onPress
    self.onStatus = onStatus

    let configuration = InputsConfiguration(sources: [.captureButton], consumeBack: false)
    let added: Inputs?
    do {
      added = try session.addInputs(configuration: configuration)
    } catch {
      setStatus(.unavailable(reason: error.localizedDescription, retryable: true))
      return
    }
    guard let added else {
      setStatus(.unavailable(reason: "The glasses session wasn't running yet.", retryable: true))
      return
    }
    inputs = added
    setStatus(.activating)

    // Register right away: neither publisher replays earlier values.
    added.statePublisher.listen { [weak self] state in
      guard let self else { return }
      Task { @MainActor in self.stateChanged(state) }
    }.store(in: tokens)
    added.errorPublisher.listen { [weak self] error in
      guard let self else { return }
      Task { @MainActor in self.failed(error) }
    }.store(in: tokens)

    let events = added.events
    eventsTask = Task { [weak self] in
      for await event in events {
        // Short press only. Hold and double press are left alone on purpose.
        guard case .capture(.shortPress, _, _) = event else { continue }
        self?.onPress?()
      }
    }
  }

  /// Stops listening and removes Inputs from the session (pass nil if it already ended).
  func detach(from session: DeviceSession?) {
    eventsTask?.cancel()
    eventsTask = nil
    tokens.clear()
    if inputs != nil {
      // An errored capability stays attached, so remove it before adding another.
      try? session?.removeInputs()
    }
    inputs = nil
    status = .off
    onPress = nil
    onStatus = nil
  }

  private func stateChanged(_ state: InputsState) {
    // After an error the capability settles to inactive; keep the error visible.
    if case .unavailable = status { return }
    switch state {
    case .activating: setStatus(.activating)
    case .active: setStatus(.active)
    case .inactive, .deactivating: setStatus(.off)
    @unknown default: break
    }
  }

  private func failed(_ error: InputsError) {
    let (reason, retryable) = Self.explain(error)
    setStatus(.unavailable(reason: reason, retryable: retryable))
  }

  private func setStatus(_ newStatus: Status) {
    guard newStatus != status else { return }
    status = newStatus
    onStatus?(newStatus)
  }

  private static func explain(_ error: InputsError) -> (String, Bool) {
    switch error {
    case .permissionDenied:
      return (
        "The glasses refused button events for this app (Inputs permission denied). "
          + "Inputs is a beta feature with no permission prompt in Meta AI. Meta has to enable it "
          + "for the app, in Wearables Developer Center or for your account.",
        false
      )
    case .capabilityUnavailable:
      return (
        "These glasses don't offer button events to apps (Inputs unavailable). "
          + "It needs Meta AI app V290+ and glasses firmware V128+, and may not be supported on this model yet.",
        false
      )
    case .activationFailed:
      return (
        "The glasses turned down button events (Inputs activation failed). "
          + "This model or firmware may not support it yet, or Meta hasn't enabled it for your account.",
        false
      )
    case .activationTimeout:
      return ("The glasses didn't respond when asked for button events (timed out).", true)
    case .connectionClosed, .deviceDisconnected, .communicationError:
      return ("Lost the button-event connection to the glasses.", true)
    @unknown default:
      return (error.localizedDescription, true)
    }
  }
}
