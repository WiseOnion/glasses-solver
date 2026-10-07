import XCTest

@testable import GlassesSolver

// MARK: - Dictating pen lines (the same cases checked in Python while the rules were written)

@MainActor
final class DictationTests: XCTestCase {
  func testPenLineTags() {
    XCTAssertEqual(Speaker.penLine(in: "Write: y, prime mark")?.0, .write)
    XCTAssertEqual(Speaker.penLine(in: "Write: y, prime mark")?.1, "y, prime mark")
    XCTAssertEqual(Speaker.penLine(in: "continue: x")?.0, .continueLine)
    XCTAssertEqual(Speaker.penLine(in: "Mark: Cross out the x.")?.0, .mark)
    XCTAssertNil(Speaker.penLine(in: "Writing is fun"))
    XCTAssertNil(Speaker.penLine(in: "Write:   "))
    // A lone "a" is read as "uh"; the capital is read as the letter.
    XCTAssertEqual(Speaker.penLine(in: "Write: letter a, small raised 2")?.1, "letter A, small raised 2")
  }

  func testProblemLabels() {
    XCTAssertEqual(Speaker.problemLabel(in: "Problem: 4"), "4")
    XCTAssertEqual(Speaker.problemLabel(in: "problem: number 7."), "number 7")
    XCTAssertNil(Speaker.problemLabel(in: "Problem:"))
    XCTAssertNil(Speaker.problemLabel(in: "Problems are fun"))
  }

  func testCues() {
    XCTAssertEqual(Speaker.cue(for: .init(kind: .write, text: "x", number: 2)), "Start line 2.")
    XCTAssertEqual(Speaker.cue(for: .init(kind: .continueLine, text: "x", number: 2)), "Same line, keep going.")
    XCTAssertEqual(Speaker.cue(for: .init(kind: .mark, text: "x", number: 2)), "")
  }

  func testLinesSplitIntoWritableParts() {
    XCTAssertEqual(
      Speaker.dictationGroups("y prime, equals, 6 x, cosine, open paren, 3 x squared, close paren."),
      ["y prime, equals, 6 x", "cosine, open paren", "3 x squared, close paren"])
    // A comma inside a number doesn't split it.
    XCTAssertEqual(Speaker.dictationGroups("y prime, equals, 1,000 x squared"), ["y prime, equals", "1,000 x squared"])
    // A part that writes nothing yet leads into the next one.
    XCTAssertEqual(
      Speaker.dictationGroups("fraction, top, sine of 5 x, bottom, 5 x, end fraction"),
      ["fraction, top, sine of 5 x", "bottom, 5 x, end fraction"])
    // A shape description stays with the mark it describes.
    XCTAssertEqual(
      Speaker.dictationGroups("y, prime mark, a small tick at the top right, equals sign, 3, times dot, a small dot at middle height"),
      ["y, prime mark, a small tick at the top right", "equals sign, 3, times dot, a small dot at middle height"])
    XCTAssertEqual(Speaker.dictationGroups(" , ."), [])
  }

  func testWrittenCharacters() {
    XCTAssertEqual(Speaker.writtenCharacters("the letters c o s"), 3)
    XCTAssertEqual(Speaker.writtenCharacters("x, small raised 2"), 2)
    XCTAssertEqual(Speaker.writtenCharacters("x, small raised 2, back down, plus sign, 1"), 4)
    XCTAssertEqual(Speaker.writtenCharacters("start fraction, on top"), 0)
    XCTAssertEqual(Speaker.writtenCharacters("draw the fraction bar, under the bar, 2"), 2)
    XCTAssertEqual(Speaker.writtenCharacters("y, prime mark, equals sign"), 3)
    XCTAssertEqual(Speaker.writtenCharacters("1,000 x"), 5)
  }

  func testPauses() {
    XCTAssertEqual(Speaker.writingTime("close paren"), 1.2, accuracy: 0.001)
    XCTAssertEqual(Speaker.writingTime("y prime, equals, 6 x"), 3.5, accuracy: 0.001)
    XCTAssertEqual(Speaker.markPause("Draw a box around line 3."), 2)
    XCTAssertEqual(Speaker.markPause("Cross out the x on top, and the x under the bar."), 4)
    XCTAssertEqual(Speaker.markPause("a and b and c and d and e"), 8)
  }

  func testSafetyNetLeavesDictationWordingAlone() {
    for line in [
      "Write: y, prime mark, a small tick at the top right, equals sign, the letters c o s, open parenthesis, 3 x, small raised 2, close parenthesis, times dot, 6 x.",
      "Write: the letters s i n, start small raised, minus sign, 1, end small raised, x.",
      "Write: the letters l i m, then under them, small, x, arrow pointing right, 0, end under.",
      "Write: x, small raised 2, back down, plus sign, 1.",
      "Write: letter e, start small raised, 2 x, plus sign, 1, end small raised.",
      "Problem: 4",
    ] {
      XCTAssertEqual(Speaker.speakable(line), line)
    }
  }
}
