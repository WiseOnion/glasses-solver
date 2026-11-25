import Foundation
import XCTest

@testable import GlassesSolver

/// The phone's side of StepWise: reading the laptop's job reports and working out where to
/// look for the laptop. (The laptop's own tests are in `C:\Users\wisdo\stepwise\tests`.)
final class CalcBridgeTests: XCTestCase {
  /// A report exactly as `stepwise/server.py` sends it, extra fields included.
  private static let report = """
    {"id": "j00012", "seq": 12, "capture_id": "0F3A", "bytes": 247922, "received_at": 1795644428.1,
     "updated_at": 1795644430.2, "stage": "transferring", "status": "active",
     "message": "On the calculator: problem 1 in slot A (0.2 s).", "cue": {"n": 2, "text": "Answer on calculator."},
     "problems": [
       {"label": "1", "status": "sent", "slot": "A", "pages": 4, "checked": true, "answer": "x equals 4", "error": null},
       {"label": "2", "status": "solving", "slot": null, "pages": 0, "checked": null, "answer": "", "error": null}],
     "error": null, "duplicate": false}
    """

  func testReadsTheLaptopsReport() throws {
    let job = try JSONDecoder().decode(CalcBridge.Job.self, from: Data(Self.report.utf8))
    XCTAssertEqual(job.id, "j00012")
    XCTAssertEqual(job.cue, .init(n: 2, text: "Answer on calculator."))
    XCTAssertEqual(job.problems.map(\.label), ["1", "2"])
    XCTAssertEqual(job.problems[0].slot, "A")
    XCTAssertNil(job.problems[1].slot)
    XCTAssertFalse(job.isFinished)
    XCTAssertEqual(job.summary, "Problem 1 (slot A): x equals 4")
  }

  func testKnowsWhenTheLaptopIsFinished() throws {
    for (status, finished, succeeded) in [
      ("active", false, false), ("retrying", false, false), ("recovering", false, false), ("completed", true, true),
      ("partial", true, true), ("failed", true, false), ("cancelled", true, false),
    ] {
      let text = Self.report.replacingOccurrences(of: "\"status\": \"active\"", with: "\"status\": \"\(status)\"")
      let job = try JSONDecoder().decode(CalcBridge.Job.self, from: Data(text.utf8))
      XCTAssertEqual(job.isFinished, finished, status)
      XCTAssertEqual(job.succeeded, succeeded, status)
    }
  }

  func testAFailedJobsSummaryIsItsMessage() throws {
    let text = """
      {"id": "j00013", "stage": "done", "status": "failed", "message": "The photo is blank (one flat color). Take it again.",
       "cue": {"n": 1, "text": "Couldn't use that photo. Take it again."}, "problems": []}
      """
    let job = try JSONDecoder().decode(CalcBridge.Job.self, from: Data(text.utf8))
    XCTAssertEqual(job.summary, "The photo is blank (one flat color). Take it again.")
  }

  func testLooksOnTheHotspotFirstAndNeverAtThePhoneItself() {
    let hosts = CalcBridge.candidates(phoneAddresses: ["172.20.10.1"])
    XCTAssertEqual(hosts, (2...14).map { "172.20.10.\($0)" })
  }

  func testAlsoLooksAcrossTheWiFiNetworkThePhoneIsOn() {
    let hosts = CalcBridge.candidates(phoneAddresses: ["192.168.86.23"])
    XCTAssertEqual(hosts.prefix(13), (2...14).map { "172.20.10.\($0)" }[...])
    XCTAssertTrue(hosts.contains("192.168.86.40"))
    XCTAssertFalse(hosts.contains("192.168.86.23"))
    XCTAssertEqual(hosts.count, 13 + 253)
  }

  func testIgnoresAddressesThatArentPrivateOrArentAddresses() {
    let hosts = CalcBridge.candidates(phoneAddresses: ["8.8.8.8", "not an address", "300.1.1.1", "17.0.0.5"])
    XCTAssertEqual(hosts, (2...14).map { "172.20.10.\($0)" })
  }

  func testNothingAnswersWhereNoLaptopIs() async {
    // TEST-NET-1 (RFC 5737) is never routed: the probe must give up by itself, quickly.
    let found = await CalcBridge.answers(at: "192.0.2.1")
    XCTAssertFalse(found)
  }
}
