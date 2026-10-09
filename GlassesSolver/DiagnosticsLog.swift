import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import MetricKit
import Observation
import UIKit
import os

/// Timestamped diagnostic lines. Each line also goes to the unified log (Console.app on
/// a Mac), but the app keeps its own copy so it can be read and copied on the phone.
///
/// Every line is also written to a file the moment it's logged, so when iOS ends the app
/// (memory, suspension) or it crashes, the next launch still shows what was happening: the
/// end of the previous run comes first in `text`, and `reportPreviousRun` says whether it
/// ended in the middle of something.
@Observable
@MainActor
final class DiagnosticsLog {
  static let shared = DiagnosticsLog()
  private static let maxLines = 1000
  nonisolated private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "GlassesSolver", category: "diagnostics")

  private(set) var lines: [String] = []
  /// The last lines of the previous run, read from its file at launch.
  private(set) var previousRun: [String] = LogFile.shared.previousTail

  var text: String {
    let previous = previousRun.isEmpty ? [] : ["----- end of the previous run -----"] + previousRun + ["----- this run -----"]
    return (previous + lines).joined(separator: "\n")
  }

  /// Safe to call from any thread, including SDK listener callbacks.
  nonisolated static func log(_ category: String, _ message: String) {
    let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(category)] \(message)"
    logger.notice("\(line, privacy: .public)")
    LogFile.shared.write(line)
    Task { @MainActor in shared.append(line) }
  }

  func clear() {
    lines.removeAll()
    previousRun.removeAll()
  }

  private func append(_ line: String) {
    lines.append(line)
    if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
  }

  /// What the app is in the middle of (an answer, a hands-free session), kept in a file so
  /// that if iOS ends the app or it crashes, the next launch can say so. nil when idle.
  nonisolated static func setActivity(_ activity: String?) {
    LogFile.shared.setActivity(activity)
  }

  /// Run once at launch: the date and build, memory, and whether the previous run was ended
  /// partway through something (by iOS, or a crash) rather than finishing it.
  static func reportPreviousRun() {
    let info = Bundle.main.infoDictionary
    let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
    diag(
      "app",
      "launched \(Date.now.formatted(.iso8601)), version \(version), iOS \(UIDevice.current.systemVersion), "
        + "\(memoryDescription)")
    if let (activity, since) = LogFile.shared.previousActivity {
      diag(
        "app",
        "THE PREVIOUS RUN ENDED WITHOUT FINISHING: it was \(activity) (since \(since)) when it stopped. "
          + "iOS ended it (for memory or while suspended) or it crashed; its last lines are above. "
          + "iOS's own reason is logged as \"exit report\" when it delivers one.")
    }
  }

  /// This run's log file.
  nonisolated static var fileURL: URL { LogFile.shared.currentURL }

  /// Memory iOS still lets the app use before ending it.
  nonisolated static var memoryDescription: String {
    "\(os_proc_available_memory() / 1_048_576) MB of memory left to use"
  }
}

func diag(_ category: String, _ message: String) {
  DiagnosticsLog.log(category, message)
}

/// The log file for this run, and what's left of the previous run's.
private final class LogFile: @unchecked Sendable {
  static let shared = LogFile()
  private static let maxBytes = 3_000_000
  private let lock = NSLock()
  private var handle: FileHandle?
  private var bytes = 0
  private let activityURL: URL
  let currentURL: URL
  let previousTail: [String]
  /// What the previous run was doing when it stopped, and since when, if it was busy.
  let previousActivity: (String, String)?

  init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let folder = base.appending(path: "Diagnostics", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let current = folder.appending(path: "current.log")
    let previous = folder.appending(path: "previous.log")
    activityURL = folder.appending(path: "activity.txt")
    currentURL = current
    try? FileManager.default.removeItem(at: previous)
    try? FileManager.default.moveItem(at: current, to: previous)
    let old = (try? String(contentsOf: previous, encoding: .utf8)) ?? ""
    previousTail = old.split(separator: "\n").suffix(400).map(String.init)
    let activity = (try? String(contentsOf: activityURL, encoding: .utf8))?.split(separator: "\n", maxSplits: 1)
    previousActivity = activity.flatMap { $0.count == 2 ? (String($0[1]), String($0[0])) : nil }
    try? FileManager.default.removeItem(at: activityURL)
    FileManager.default.createFile(atPath: current.path, contents: nil)
    handle = try? FileHandle(forWritingTo: current)
  }

  func write(_ line: String) {
    lock.withLock {
      guard let handle, bytes < Self.maxBytes else { return }
      let data = Data((line + "\n").utf8)
      try? handle.write(contentsOf: data)
      bytes += data.count
    }
  }

  func setActivity(_ activity: String?) {
    lock.withLock {
      if let activity {
        let text = Date.now.formatted(.iso8601.time(includingFractionalSeconds: false)) + "\n" + activity
        try? Data(text.utf8).write(to: activityURL)
      } else {
        try? FileManager.default.removeItem(at: activityURL)
      }
    }
  }
}

/// Logs what happens to the app itself: going to the background and back, memory warnings,
/// termination, uncaught exceptions, and the crash and exit reports iOS delivers through
/// MetricKit (why the app was ended: memory, a watchdog, a crash, and so on).
final class AppEventsLog: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
  static let shared = AppEventsLog()
  private static let lastReportKey = "lastExitReportEnd"

  func start() {
    let center = NotificationCenter.default
    let events: [(Notification.Name, String)] = [
      (UIApplication.didEnterBackgroundNotification, "went to the background"),
      (UIApplication.willEnterForegroundNotification, "coming back to the foreground"),
      (UIApplication.protectedDataWillBecomeUnavailableNotification, "phone locked"),
      (UIApplication.protectedDataDidBecomeAvailableNotification, "phone unlocked"),
      (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING from iOS"),
      (UIApplication.willTerminateNotification, "iOS is closing the app"),
    ]
    for (name, text) in events {
      _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
        diag("app", "\(text) (\(DiagnosticsLog.memoryDescription))")
      }
    }
    NSSetUncaughtExceptionHandler { exception in
      diag("app", "CRASH: \(exception.name.rawValue): \(exception.reason ?? "") at \(exception.callStackSymbols.prefix(12))")
    }
    MXMetricManager.shared.add(self)
    report(MXMetricManager.shared.pastDiagnosticPayloads)
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) { report(payloads) }

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      guard let exits = payload.applicationExitMetrics else { continue }
      diag("app", "exit report (how the app ended, \(payload.timeStampBegin) to \(payload.timeStampEnd)): "
        + String(decoding: exits.jsonRepresentation(), as: UTF8.self))
    }
  }

  /// Logs crash reports not logged before.
  private func report(_ payloads: [MXDiagnosticPayload]) {
    let last = UserDefaults.standard.object(forKey: Self.lastReportKey) as? Date ?? .distantPast
    for payload in payloads where payload.timeStampEnd > last {
      UserDefaults.standard.set(payload.timeStampEnd, forKey: Self.lastReportKey)
      for crash in payload.crashDiagnostics ?? [] {
        let tree = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
        diag(
          "app",
          "exit report: CRASH between \(payload.timeStampBegin) and \(payload.timeStampEnd), version "
            + "\(crash.metaData.applicationBuildVersion): exception \(crash.exceptionType.map { "\($0)" } ?? "-"), "
            + "code \(crash.exceptionCode.map { "\($0)" } ?? "-"), signal \(crash.signal.map { "\($0)" } ?? "-"), "
            + "\(crash.terminationReason ?? "no termination reason"); \(crash.virtualMemoryRegionInfo ?? ""); "
            + "stack \(tree.prefix(2500))")
      }
      let hangs = payload.hangDiagnostics?.count ?? 0
      let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
      if hangs + cpu > 0 { diag("app", "exit report: \(hangs) hangs, \(cpu) CPU limit reports") }
    }
  }
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
      case .stream(.thermalHot):
        return "Let the glasses cool down for a few minutes."
      case .stream(.batteryLow), .stream(.peakPowerLimit):
        return "Charge the glasses, then try again."
      case .stream(.hingesClosed):
        return "Open the glasses' hinges and put them on."
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
    case let error as StreamError: return "StreamError." + name(error)
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

  private static func name(_ error: StreamError) -> String {
    switch error {
    case .internalError: "internalError"
    case .deviceNotFound: "deviceNotFound"
    case .deviceNotConnected: "deviceNotConnected"
    case .timeout: "timeout"
    case .videoStreamingError: "videoStreamingError"
    case .audioStreamingError: "audioStreamingError"
    case .permissionDenied: "permissionDenied"
    case .hingesClosed: "hingesClosed"
    case .thermalHot: "thermalHot"
    case .batteryLow: "batteryLow"
    case .peakPowerLimit: "peakPowerLimit"
    case .photoCaptureFailed: "photoCaptureFailed"
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
