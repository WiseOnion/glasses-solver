import Foundation
import XCTest

@testable import GlassesSolver

/// An answer must never stop partway: speech that gets stuck starts again where it was, a
/// hold for the glasses' audio ends on its own, and the reason is always in the log.
@MainActor
final class ReliabilityTests: XCTestCase {
  private static let longAnswer = """
    I can see problem 3.
    Problem: 3
    This is the derivative of x squared.
    You'll write two lines.
    Write: y equals, x squared, plus 3 x, minus 7
    Write: y prime equals, 2 x, plus 3
    Mark: Draw a box around line 2.
    Done.
    """

  override func tearDown() async throws {
    Speaker.maxHold = 30
    try await super.tearDown()
  }

  func testStuckSpeechStartsAgainFromWhereItWas() async {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak(Self.longAnswer, isAnswer: true)
    let total = speaker.queued.count
    XCTAssertTrue(speaker.isActive)
    speaker.simulateStallForTesting()
    let recovered = await waitUntil(5) { DiagnosticsLog.shared.text.contains("SPEECH STUCK") }
    XCTAssertTrue(recovered, "the watchdog never noticed the stuck speech")
    // What was left is queued again, and still being said.
    XCTAssertTrue(speaker.isActive)
    XCTAssertGreaterThan(speaker.queued.count, 0)
    XCTAssertLessThanOrEqual(speaker.queued.count, total)
    XCTAssertEqual(speaker.queued.last?.text, "Done.")
  }

  func testAHoldForTheGlassesAudioEndsOnItsOwn() async {
    Speaker.maxHold = 2
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak(Self.longAnswer, isAnswer: true)
    speaker.simulateRouteLossForTesting()
    XCTAssertTrue(speaker.heldForRoute, "a lost route should hold speech")
    let released = await waitUntil(8) { !speaker.heldForRoute }
    XCTAssertTrue(released, "the hold never ended, so the answer would have gone silent for good")
    let logged = await waitUntil(2) { DiagnosticsLog.shared.text.contains("hasn't come back") }
    XCTAssertTrue(logged)
  }

  func testStoppingAnAnswerLogsWhy() async {
    let speaker = Speaker()
    speaker.beginAnswer()
    speaker.continueAnswer("Problem: 3\nWrite: x\n")
    speaker.stop("a test")
    let logged = await waitUntil(2) { DiagnosticsLog.shared.text.contains("answer stopped before the end: a test") }
    XCTAssertTrue(logged)
  }

  func testAPauseInAnArrivingAnswerIsFilled() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.beginAnswer()
    // Nothing said yet and nothing queued: a pause while Claude writes gets a cue.
    XCTAssertTrue(speaker.sayWhileWaiting("Still working.", after: 0))
    XCTAssertEqual(speaker.queued.map(\.text), ["Still working."])
    // While something is being said, nothing is added.
    XCTAssertFalse(speaker.sayWhileWaiting("Still working.", after: 0))
  }

  func testAzureAudioIsReadFromAnyByteOffset() {
    // Two samples starting at an odd offset, so the bytes aren't aligned for 16-bit reads.
    var bytes = Data([0xFF])
    bytes.append(contentsOf: [0x00, 0x40, 0x00, 0xC0, 0x01])
    let samples = NeuralVoice.pcmSamples(bytes.dropFirst())
    XCTAssertEqual(samples.count, 2)  // the odd last byte is left out
    XCTAssertEqual(samples[0], 0.5, accuracy: 0.0001)
    XCTAssertEqual(samples[1], -0.5, accuracy: 0.0001)
  }
}
