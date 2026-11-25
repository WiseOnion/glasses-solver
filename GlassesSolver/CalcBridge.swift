import Foundation

/// The StepWise laptop: it takes a photo, finds and solves the problems, and shows the work on
/// the TI-84. The phone only uploads the photo and asks how it's going (plain HTTP on the
/// hotspot; the laptop side is `C:\Users\wisdo\stepwise`, see `stepwise/server.py`).
struct CalcBridge: Sendable {
  static let port = 8765
  static let appName = "StepWise"

  /// One photo's progress on the laptop, as `GET /jobs/<id>` reports it.
  struct Job: Decodable, Sendable, Equatable {
    struct Cue: Decodable, Sendable, Equatable {
      let n: Int
      let text: String
    }
    struct Problem: Decodable, Sendable, Equatable {
      let label: String
      let status: String
      let slot: String?
      let answer: String?
    }
    let id: String
    let status: String
    let stage: String
    let message: String
    let cue: Cue
    let problems: [Problem]

    /// The laptop is finished with this photo, one way or another.
    var isFinished: Bool { ["completed", "partial", "failed", "cancelled"].contains(status) }
    var succeeded: Bool { status == "completed" || status == "partial" }
    /// What to keep in the phone's history: each answer and the calculator slot it's in.
    var summary: String {
      let lines = problems.filter { $0.status == "sent" }.map { problem in
        "Problem \(problem.label) (slot \(problem.slot ?? "?")): \(problem.answer ?? "")"
      }
      return lines.isEmpty ? message : lines.joined(separator: "\n")
    }
  }

  private struct Health: Decodable {
    let name: String
  }

  enum BridgeError: LocalizedError, Equatable {
    case notFound
    case refused(Int, String)
    case badReply

    var errorDescription: String? {
      switch self {
      case .notFound:
        "Can't find the StepWise laptop. Start StepWise on the laptop and join it to this phone's hotspot."
      case .refused(let code, let reason): "The laptop refused the photo (\(code)): \(reason)"
      case .badReply: "The laptop's reply wasn't understood. Update StepWise on the laptop."
      }
    }
  }

  let host: String

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.waitsForConnectivity = false
    config.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: config)
  }()

  /// Short timeouts, many hosts at once: only for looking for the laptop.
  private static let probeSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 1.5
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  private static func url(_ host: String, _ path: String) -> URL? {
    URL(string: "http://\(host):\(port)\(path)")
  }

  // MARK: - Finding the laptop

  /// True if a StepWise bridge answers at this address.
  static func answers(at host: String) async -> Bool {
    guard let url = url(host, "/health") else { return false }
    guard let (data, response) = try? await probeSession.data(from: url),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let health = try? JSONDecoder().decode(Health.self, from: data)
    else { return false }
    return health.name == appName
  }

  /// Every other address on the phone's own networks. With the hotspot on that's
  /// 172.20.10.2 to .14, where iOS puts the devices that join it; on Wi-Fi it's the phone's /24.
  static func candidates(phoneAddresses: [String]) -> [String] {
    var hosts: [String] = []
    // The hotspot range first, even before the phone reports that interface.
    for address in ["172.20.10.1"] + phoneAddresses {
      let parts = address.split(separator: ".").compactMap { Int($0) }
      guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { continue }
      let isPrivate =
        parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
      guard isPrivate else { continue }
      let last = parts[0] == 172 && parts[1] == 20 && parts[2] == 10 ? 14 : 254
      for n in 1...last where n != parts[3] {
        let host = "\(parts[0]).\(parts[1]).\(parts[2]).\(n)"
        if !hosts.contains(host) { hosts.append(host) }
      }
    }
    return hosts
  }

  /// The phone's own IPv4 addresses on Wi-Fi (en) and the hotspot (bridge).
  static func phoneAddresses() -> [String] {
    var result: [String] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: entry.pointee.ifa_name)
      guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        let length = host.firstIndex(of: 0) ?? host.count
        result.append(String(decoding: host[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
    }
    return result
  }

  /// The laptop's address: the one that worked last time if it still answers, otherwise a look
  /// around the phone's networks. The laptop's address changes between hotspot sessions, so
  /// nothing is ever typed in.
  static func find(saved: String?) async -> String? {
    if let saved, !saved.isEmpty, await answers(at: saved) { return saved }
    let hosts = candidates(phoneAddresses: phoneAddresses())
    return await withTaskGroup(of: String?.self) { group in
      for host in hosts {
        group.addTask { await answers(at: host) ? host : nil }
      }
      for await found in group {
        if let found {
          group.cancelAll()
          return found
        }
      }
      return nil
    }
  }

  // MARK: - One photo

  private func decode(_ data: Data, _ response: URLResponse) throws -> Job {
    guard let http = response as? HTTPURLResponse else { throw BridgeError.badReply }
    guard (200...299).contains(http.statusCode) else {
      let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw BridgeError.refused(http.statusCode, reason ?? "no reason given")
    }
    guard let job = try? JSONDecoder().decode(Job.self, from: data) else { throw BridgeError.badReply }
    return job
  }

  /// Sends the photo. The capture ID makes a repeat harmless: if the first try reached the
  /// laptop but its reply was lost, the second gets the same job back, never a second one.
  func upload(jpeg: Data, captureID: String) async throws -> Job {
    guard let url = Self.url(host, "/jobs") else { throw BridgeError.notFound }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.setValue(captureID, forHTTPHeaderField: "X-Capture-Id")
    request.timeoutInterval = 30
    var lastError: Error = BridgeError.notFound
    for attempt in 0..<3 {
      if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
      do {
        let (data, response) = try await Self.session.upload(for: request, from: jpeg)
        return try decode(data, response)
      } catch let error as BridgeError {
        throw error  // the laptop answered and said no: sending it again won't change that
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  func job(_ id: String) async throws -> Job {
    guard let url = Self.url(host, "/jobs/\(id)") else { throw BridgeError.notFound }
    let (data, response) = try await Self.session.data(from: url)
    return try decode(data, response)
  }
}
