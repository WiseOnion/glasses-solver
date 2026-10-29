import Foundation
import MWDATCore
import MWDATInputs

/// Listens for the glasses' physical controls (capture button and touchpad), using the SDK
/// 1.0 Inputs capability (experimental). Every gesture an app can receive is passed on; the
/// owner decides what each one does.
///
/// Field notes from Meta's BirdSpotter sample, which this follows:
/// - Requested alone, `.captureButton` once reported `active` and then delivered nothing,
///   so the temple touchpad and action button are requested too. The touchpad's single tap
///   (pause/resume) and tap-and-hold (end session) stay reserved by the glasses either way,
///   and volume stays with the system.
/// - Taking a photo can drop the capability (it goes `inactive` after being `active`), and
///   it doesn't come back by itself. That is reported as `.off` so the owner can re-add it.
@MainActor
final class ShutterButton {
  enum Status: Equatable {
    case off
    case activating
    case active
    /// `retryable` is false when trying again won't help (permission or hardware).
    case unavailable(reason: String, retryable: Bool)
  }

  /// A gesture the glasses deliver to apps (Meta's Inputs page). Whether each one reaches
  /// the app on a given model and firmware is only known from real glasses, so every event is
  /// logged.
  enum Gesture: Equatable, CustomStringConvertible {
    case capturePress
    case captureDoublePress
    case captureHold
    /// A touchpad double-tap, delivered as Select (Meta, SDK issue #312). It doesn't pause
    /// the session, unlike a single tap.
    case touchpadDoubleTap
    /// A touchpad swipe. Which direction is "forward" depends on the model and the wearer's
    /// settings (they can invert it), so the owner maps it.
    case swipe(Swipe)

    enum Swipe: String, Equatable { case up, down, left, right }

    var description: String {
      switch self {
      case .capturePress: "capture button, short press"
      case .captureDoublePress: "capture button, double press"
      case .captureHold: "capture button, hold"
      case .touchpadDoubleTap: "touchpad double-tap"
      case .swipe(let direction): "touchpad swipe \(direction.rawValue)"
      }
    }
  }

  private(set) var status: Status = .off
  private var inputs: Inputs?
  private var hasActivated = false
  /// Bumped on every attach, so callbacks still in flight from a removed capability are ignored.
  private var generation = 0
  private var eventsTask: Task<Void, Never>?
  private let tokens = ListenerTokenBag()
  private var onGesture: ((Gesture, Int64) -> Void)?
  private var onStatus: ((Status) -> Void)?

  /// Attaches Inputs to a started session. Gestures arrive on `onGesture` with the glasses'
  /// own timestamp in milliseconds; activation progress and failures on `onStatus`.
  func attach(
    to session: DeviceSession,
    onGesture: @escaping (Gesture, Int64) -> Void,
    onStatus: @escaping (Status) -> Void
  ) {
    detach(from: session)
    self.onGesture = onGesture
    self.onStatus = onStatus

    // consumeBack keeps a back gesture from ending the session (real glasses don't send
    // Back yet, per the docs, but the sample sets it for that reason).
    let configuration = InputsConfiguration(
      sources: [.captouch, .captureButton, .actionButton], consumeBack: true)
    diag("inputs", "addInputs(sources: captouch, captureButton, actionButton), session state \(session.state)")
    let added: Inputs?
    do {
      added = try session.addInputs(configuration: configuration)
    } catch {
      let detail = ErrorDetail.describe(error)
      diag("inputs", "addInputs FAILED: \(detail)")
      setStatus(.unavailable(reason: "\(error.localizedDescription) (\(detail))", retryable: true))
      return
    }
    guard let added else {
      diag("inputs", "addInputs returned nil (session state \(session.state))")
      setStatus(.unavailable(reason: "The glasses reported no button inputs for this session.", retryable: true))
      return
    }
    diag("inputs", "addInputs OK, initial state \(added.state)")
    inputs = added
    hasActivated = false
    generation += 1
    let current = generation
    setStatus(.activating)

    // Register right away: neither publisher replays earlier values.
    added.statePublisher.listen { [weak self] state in
      diag("inputs", "state -> \(state)")
      guard let self else { return }
      Task { @MainActor in
        guard self.generation == current else { return }
        self.stateChanged(state)
      }
    }.store(in: tokens)
    added.errorPublisher.listen { [weak self] error in
      diag("inputs", "error: \(ErrorDetail.describe(error))")
      guard let self else { return }
      Task { @MainActor in
        guard self.generation == current else { return }
        self.failed(error)
      }
    }.store(in: tokens)

    let events = added.events
    eventsTask = Task { [weak self] in
      for await event in events {
        // Everything is logged, including ignored events: whether a gesture arrives at all,
        // and as which type, is only known from real glasses.
        guard let gesture = Self.gesture(for: event) else {
          diag("inputs", "event (ignored): \(event)")
          continue
        }
        diag("inputs", "event: \(gesture) at \(event.timestampMs) ms")
        guard self?.generation == current else { return }
        self?.onGesture?(gesture, event.timestampMs)
      }
      // A stream that ends on its own means no more presses, even without an `inactive`.
      guard !Task.isCancelled, self?.generation == current else { return }
      diag("inputs", "event stream ended")
      self?.streamEnded()
    }

    // Activation starts inside addInputs and the publishers don't replay, so a quick
    // `active` can come and go before the listeners above exist. `state` is always current:
    // catch up from it now, and keep checking while this still looks like it's activating.
    catchUp(with: added, generation: current)
    Task { [weak self] in
      for _ in 0..<10 {
        try? await Task.sleep(for: .seconds(1))
        guard let self, self.generation == current, self.status == .activating else { return }
        self.catchUp(with: added, generation: current)
      }
    }
  }

  private func catchUp(with inputs: Inputs, generation: Int) {
    guard self.generation == generation else { return }
    let state = inputs.state
    if state == .active, status == .activating {
      diag("inputs", "state is already active (no event was heard)")
      stateChanged(.active)
    }
  }

  /// Stops listening and removes Inputs from the session (pass nil if it already ended).
  func detach(from session: DeviceSession?) {
    generation += 1
    eventsTask?.cancel()
    eventsTask = nil
    tokens.clear()
    if inputs != nil {
      // An errored or dropped capability stays attached, so remove it before adding another.
      do {
        try session?.removeInputs()
        diag("inputs", "removeInputs OK")
      } catch {
        diag("inputs", "removeInputs FAILED: \(ErrorDetail.describe(error))")
      }
    }
    inputs = nil
    hasActivated = false
    status = .off
    onGesture = nil
    onStatus = nil
  }

  /// The gesture an event stands for; nil for events this app doesn't use (the action button,
  /// Back, drags, and anything from a source other than the temple and the capture button).
  nonisolated static func gesture(for event: InputEvent) -> Gesture? {
    switch event {
    case .capture(let press, .captureButton, _):
      switch press {
      case .shortPress: .capturePress
      case .doublePress: .captureDoublePress
      case .hold: .captureHold
      }
    case .select(.captouch, _):
      .touchpadDoubleTap
    case .nav(let direction, .captouch, _):
      switch direction {
      case .up: .swipe(.up)
      case .down: .swipe(.down)
      case .left: .swipe(.left)
      case .right: .swipe(.right)
      }
    default:
      nil
    }
  }

  private func stateChanged(_ state: InputsState) {
    // After an error the capability settles to inactive; keep the error visible.
    if case .unavailable = status { return }
    switch state {
    case .activating:
      setStatus(.activating)
    case .active:
      hasActivated = true
      setStatus(.active)
    case .inactive:
      // `inactive` is also the state it starts in; only a drop after `active` counts.
      if hasActivated { setStatus(.off) }
    case .deactivating:
      break
    @unknown default:
      break
    }
  }

  private func streamEnded() {
    if case .unavailable = status { return }
    setStatus(.off)
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
