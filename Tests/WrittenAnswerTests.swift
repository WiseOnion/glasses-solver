import XCTest

@testable import GlassesSolver

/// The written math shown on the phone: parsed from the LaTeX after "||", never spoken.
@MainActor
final class WrittenAnswerTests: XCTestCase {
  private static let answer = #"""
    I can see problem 4.
    Problem: 4
    This is the derivative of f of x, using the limit definition.
    You'll write two lines.
    First, write the limit definition.
    Write: f prime of x equals, the limit as h approaches 0, of a fraction || f'(x) = \lim_{h \to 0} \frac{h(x + 1)}{h}
    Continue: on top, you have h, times open parenthesis, x plus 1, close parenthesis
    Continue: on the bottom, you have h
    Now cancel the h.
    Mark: On line 1, cross out both h's. || line 1: f'(x) = \lim_{h \to 0} \frac{\cancel{h}(x + 1)}{\cancel{h}}
    Now simplify. This is the answer.
    Write: equals x plus 1 || = x + 1
    Mark: Draw a box around line 2.
    Done.
    """#

  func testLinesCrossOutsBoxAndNotes() {
    let written = WrittenAnswer.parse(Self.answer)
    XCTAssertFalse(written.isEmpty)
    XCTAssertEqual(written.problems.map(\.label), ["4"])
    let lines = written.problems[0].lines
    XCTAssertEqual(lines.map(\.number), [1, 2])
    // The cross-out replaces line 1 with its crossed-out version.
    XCTAssertEqual(lines[0].math, #"f'(x) = \lim_{h \to 0} \frac{\cancel{h}(x + 1)}{\cancel{h}}"#)
    XCTAssertEqual(lines[0].note, "First, write the limit definition.")
    XCTAssertEqual(lines[1].math, "= x + 1")
    XCTAssertTrue(lines[1].boxed)
    XCTAssertFalse(lines[0].boxed)
    XCTAssertEqual(lines[1].note, "Now simplify. This is the answer.")
    // The line being said is marked, and the math is typeset as display math.
    let html = written.html(now: ("4", 2))
    XCTAssertTrue(html.contains(#"id="now""#))
    XCTAssertTrue(html.contains(#"\(\displaystyle = x + 1\)"#))
    XCTAssertTrue(html.contains("boxed"))
  }

  func testTheWrittenMathIsNeverSpoken() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak(Self.answer)
    let spoken = speaker.queued.map(\.text).joined(separator: " ")
    XCTAssertFalse(spoken.contains("\\"), "LaTeX reached the voice: \(spoken)")
    XCTAssertFalse(spoken.contains("||"))
    XCTAssertEqual(Speaker.spokenPart("Write: x || x"), "Write: x")
    XCTAssertEqual(Speaker.spokenPart("Write: x"), "Write: x")
  }

  func testAnAnswerWithoutWrittenMathShowsWords() {
    XCTAssertTrue(WrittenAnswer.parse("Problem: 3\nWrite: y equals 2").isEmpty)
  }

  func testTheLineNumberIsSaidOnItsOwn() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak("Problem: 3\nWrite: 1, plus tangent w")
    // "Start line 1." then a pause, so "1" isn't heard as part of the line number.
    XCTAssertEqual(speaker.queued.map(\.text), ["Problem 3.", "Start line 1.", "1, plus tangent w."])
    XCTAssertEqual(speaker.queued[1].pause, 0.5, accuracy: 0.001)
  }

  func testHeartMakesLongPiecesASentenceAtATime() {
    XCTAssertEqual(
      NeuralVoice.sentences("This is the derivative of x squared. You'll write two lines. First, write it down."),
      ["This is the derivative of x squared.", "You'll write two lines.", "First, write it down."])
    // A one- or two-word sentence joins the next.
    XCTAssertEqual(NeuralVoice.sentences("Done. That is all for now."), ["Done. That is all for now."])
    XCTAssertEqual(NeuralVoice.sentences("u equals, 1, plus tangent w,"), ["u equals, 1, plus tangent w,"])
  }
}
