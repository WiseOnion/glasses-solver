import Foundation
import MWDATCore
import MWDATInputs
import Observation
import os

/// Timestamped diagnostic lines. Each line also goes to the unified log (Console.app on
/// a Mac), but the app keeps its own copy so it can be read and copied on the phone.
@Observable
@MainActor
final class DiagnosticsLog {
  static let shared = DiagnosticsLog()
  private static let maxLines = 500
  nonisolated private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "GlassesSolver", category: "diagnostics")

  private(set) var lines: [String] = []

  var text: String { lines.joined(separator: "\n") }

  /// Safe to call from any thread, including SDK listener callbacks.
  nonisolated static func log(_ category: String, _ message: String) {
    let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(category)] \(message)"
    logger.notice("\(line, privacy: .public)")
    Task { @MainActor in shared.append(line) }
  }

  func clear() { lines.removeAll() }

  private func append(_ line: String) {
    lines.append(line)
    if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
  }
}

func diag(_ category: String, _ message: String) {
  DiagnosticsLog.log(category, message)
}

/// Describes an error by type, case, and NSError domain/code, so a generic message such
/// as "The operation couldn't be completed" still says where it came from.
enum ErrorDetail {
  static func describe(_ error: Error) -> String {
    let ns = error as NSError
    var text = "\(caseName(error) ?? String(reflecting: type(of: error))) [\(ns.domain) \(ns.code)]: "
      + error.localizedDescription
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
      text += " <- " + describe(underlying)
    }
    return text
  }

  /// The message for an alert: the readable text, a next step when one is known, then the
  /// details to report back.
  static func alertText(_ error: Error) -> String {
    var text = error.localizedDescription
    if let hint = hint(error) { text += "\n\nWhat to try: \(hint)" }
    return text + "\n\nDetails: \(describe(error))"
  }

  /// Next steps for failures Meta documents or has answered in the SDK's GitHub issues.
  private static func hint(_ error: Error) -> String? {
    switch error {
    case let error as DeviceSessionError:
      switch error {
      case .noEligibleDevice:
        return "Open the hinges and put the glasses on, check they show as connected in Meta AI, "
          + "and that their firmware is V128 or newer (Meta AI app V290 or newer)."
      case .datAppOnTheGlassesUpdateRequired:
        return "In Meta AI, open App connections and update the app on the glasses."
      case .dwaUnavailable:
        return "The toolkit app on the glasses isn't reachable. In Meta AI, check Developer Mode is on "
          + "and tap Install next to your glasses if it's shown, then restart the glasses."
      case .unexpectedError:
        return "Turn the glasses off with the power switch and back on, then try again. If Meta AI shows "
          + "\"broadcast in progress\", stop it there first."
      case .insufficientSDKVersion:
        return "Your glasses need a newer SDK than this build uses. The app needs a rebuild."
      case .sessionAlreadyExists:
        return "Another app may be using the glasses. Close it, wait a few seconds, and try again."
      case .thermalCritical, .thermalEmergency, .peakPowerShutdown, .batteryCritical:
        return "Let the glasses cool down or charge them, then try again."
      default:
        return nil
      }
    case let error as PermissionError:
      switch error {
      case .metaAINotInstalled:
        return "Install the Meta AI app."
      case .noDevice, .noDeviceWithConnection:
        return "Make sure the glasses are on and connected in Meta AI."
      case .connectionError, .requestTimeout, .internalError:
        return "Update the Meta AI app, force-quit it, and try again. If Meta AI itself shows "
          + "\"Internal error\", turn Developer Mode off and on in Meta AI, then disconnect and reconnect "
          + "the glasses in this app's Settings."
      default:
        return nil
      }
    case let error as GlassesError:
      switch error {
      case .timedOut, .sessionEnded:
        return "Check the glasses are on, worn, and connected in Meta AI. If it keeps happening, "
          + "turn them off and on with the power switch."
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private static func caseName(_ error: Error) -> String? {
    switch error {
    case let error as DeviceSessionError: return "DeviceSessionError." + name(error)
    case let error as PermissionError: return "PermissionError." + name(error)
    case let error as WearablesError: return "WearablesError." + name(error)
    case let error as InputsError: return "InputsError." + name(error)
    default: return nil
    }
  }

  private static func name(_ error: DeviceSessionError) -> String {
    switch error {
    case .noEligibleDevice: "noEligibleDevice"
    case .sessionAlreadyStopped: "sessionAlreadyStopped"
    case .sessionAlreadyExists: "sessionAlreadyExists"
    case .sessionIdle: "sessionIdle"
    case .capabilityAlreadyActive: "capabilityAlreadyActive"
    case .capabilityNotFound: "capabilityNotFound"
    case .unexpectedError(let description): "unexpectedError(\(description))"
    case .thermalCritical: "thermalCritical"
    case .thermalEmergency: "thermalEmergency"
    case .peakPowerShutdown: "peakPowerShutdown"
    case .batteryCritical: "batteryCritical"
    case .datAppOnTheGlassesUpdateRequired: "datAppOnTheGlassesUpdateRequired"
    case .dwaUnavailable: "dwaUnavailable"
    case .insufficientSDKVersion: "insufficientSDKVersion"
    case .dwaOutOfStuRange: "dwaOutOfStuRange"
    @unknown default: "unknown"
    }
  }

  private static func name(_ error: PermissionError) -> String {
    switch error {
    case .noDevice: "noDevice"
    case .noDeviceWithConnection: "noDeviceWithConnection"
    case .connectionError: "connectionError"
    case .metaAINotInstalled: "metaAINotInstalled"
    case .requestInProgress: "requestInProgress"
    case .requestTimeout: "requestTimeout"
    case .internalError: "internalError"
    @unknown default: "unknown"
    }
  }

  private static func name(_ error: WearablesError) -> String {
    switch error {
    case .internalError: "internalError"
    case .alreadyConfigured: "alreadyConfigured"
    case .configurationError: "configurationError"
    case .missingInfoDictionary: "missingInfoDictionary"
    case .missingBundleIdentifier: "missingBundleIdentifier"
    case .missingAppName: "missingAppName"
    case .missingAppVersion: "missingAppVersion"
    case .missingBuildNumber: "missingBuildNumber"
    @unknown default: "unknown"
    }
  }

  private static func name(_ error: InputsError) -> String {
    switch error {
    case .permissionDenied: "permissionDenied"
    case .connectionClosed: "connectionClosed"
    case .activationTimeout: "activationTimeout"
    case .activationFailed: "activationFailed"
    case .capabilityUnavailable: "capabilityUnavailable"
    case .deviceDisconnected: "deviceDisconnected"
    case .communicationError: "communicationError"
    @unknown default: "unknown"
    }
  }
}
