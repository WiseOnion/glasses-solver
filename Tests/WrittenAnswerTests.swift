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
    // The page gets the steps as data: the line being said marked, each line split at its
    // equals sign so the signs line up.
    let data = try? JSONSerialization.jsonObject(with: Data(written.pageData(now: ("4", 2)).utf8))
    let problems = data as? [[String: Any]]
    let steps = problems?.first?["lines"] as? [[String: Any]]
    XCTAssertEqual(steps?.count, 2)
    XCTAssertEqual(steps?[1]["now"] as? Bool, true)
    XCTAssertEqual(steps?[0]["now"] as? Bool, false)
    XCTAssertEqual(steps?[1]["boxed"] as? Bool, true)
    XCTAssertEqual(steps?[1]["left"] as? String, "")
    XCTAssertEqual(steps?[1]["right"] as? String, "= x + 1")
    XCTAssertEqual(steps?[0]["left"] as? String, "f'(x)")
    XCTAssertEqual(steps?[1]["words"] as? String, "equals x plus 1")
  }

  /// The examples from the writing spec: each splits at its first relation outside any group,
  /// so the equals signs line up, and the math itself is left as it is.
  func testEqualsSignsLineUp() {
    func parts(_ latex: String) -> [String]? {
      WrittenAnswer.alignedParts(latex).map { [$0.left, $0.right] }
    }
    XCTAssertEqual(parts("24+18=42"), ["24+18", "=42"])
    XCTAssertEqual(parts(#"=\frac{3}{4}+\frac{2}{4}"#), ["", #"=\frac{3}{4}+\frac{2}{4}"#])
    XCTAssertEqual(parts(#"x^2\cdot x^3=x^{2+3}"#), [#"x^2\cdot x^3"#, "=x^{2+3}"])
    XCTAssertEqual(parts(#"\sqrt{x^2+9}=5"#), [#"\sqrt{x^2+9}"#, "=5"])
    XCTAssertEqual(
      parts(#"x-3=0\quad\text{or}\quad x+3=0"#), ["x-3", #"=0\quad\text{or}\quad x+3=0"#])
    XCTAssertEqual(parts(#"\frac{dy}{dx}=3x^2+4x-5"#), [#"\frac{dy}{dx}"#, "=3x^2+4x-5"])
    XCTAssertEqual(parts("2x+1<9"), ["2x+1", "<9"])
    XCTAssertEqual(parts(#"x\geq 0"#), ["x", #"\geq 0"#])
    XCTAssertEqual(parts(#"\frac{(x-2)(x+2)}{x-2}=x+2,\quad x\ne2"#), [#"\frac{(x-2)(x+2)}{x-2}"#, #"=x+2,\quad x\ne2"#])
    // A relation inside a group, a case or a matrix isn't where the line lines up.
    XCTAssertEqual(
      parts(#"f(x)=\begin{cases}x^2,&x\geq0\\-x,&x<0\end{cases}"#),
      ["f(x)", #"=\begin{cases}x^2,&x\geq0\\-x,&x<0\end{cases}"#])
    XCTAssertEqual(parts(#"\sum_{i=1}^{n}i"#), nil)
    XCTAssertEqual(parts(#"\left(x=1\right)"#), nil)
    XCTAssertEqual(parts(#"\lim_{x\to2}\frac{x^2-4}{x-2}"#), nil)
    XCTAssertEqual(parts(#"(-\infty,4)"#), nil)
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

  /// A long line Claude broke with \\ for the phone becomes rows; a \\ inside cases or a
  /// matrix stays where it is.
  func testLongLinesBreakIntoRows() {
    XCTAssertEqual(
      WrittenAnswer.rows(#"= -3x^2 - 6xh - 3h^2 \\ + 8x + 8h - 2"#), ["= -3x^2 - 6xh - 3h^2", "+ 8x + 8h - 2"])
    XCTAssertEqual(
      WrittenAnswer.rows(#"f(x)=\begin{cases}x^2,&x\geq0\\-x,&x<0\end{cases}"#),
      [#"f(x)=\begin{cases}x^2,&x\geq0\\-x,&x<0\end{cases}"#])
    XCTAssertEqual(
      WrittenAnswer.rows(#"A=\begin{bmatrix}1&2\\3&4\end{bmatrix}"#), [#"A=\begin{bmatrix}1&2\\3&4\end{bmatrix}"#])
    let written = WrittenAnswer.parse(#"Problem: 1"# + "\n" + #"Write: equals, a lot || = a + b \\ + c"#)
    let data = try? JSONSerialization.jsonObject(with: Data(written.pageData(now: nil).utf8)) as? [[String: Any]]
    let step = (data?.first?["lines"] as? [[String: Any]])?.first
    XCTAssertEqual(step?["right"] as? String, "= a + b")
    XCTAssertEqual(step?["more"] as? [String], ["+ c"])
    // Step sentences stay in the voice; the page gets only the math.
    XCTAssertNil(step?["note"])
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
