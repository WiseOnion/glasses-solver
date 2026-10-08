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
    // The same inside spelled letters, but not a shape description after them.
    XCTAssertEqual(
      Speaker.penLine(in: "Write: 1, plus sign, the letters t a n, w")?.1, "1, plus sign, the letters t A n, w")
    XCTAssertEqual(Speaker.penLine(in: "Write: the letters a r c")?.1, "the letters A r c")
    XCTAssertEqual(
      Speaker.penLine(in: "Write: the letters c o s, a small tick")?.1, "the letters c o s, a small tick")
  }

  func testPlainWordingIsCounted() {
    // Words that only say where to write put nothing on paper; math words count their marks.
    XCTAssertEqual(Speaker.writtenCharacters("secant squared w"), 5)
    XCTAssertEqual(Speaker.writtenCharacters("the limit as h approaches 0"), 6)
    XCTAssertEqual(Speaker.writtenCharacters("natural log of x"), 3)
    XCTAssertEqual(Speaker.writtenCharacters("log base 2 of x"), 4)
    XCTAssertEqual(Speaker.writtenCharacters("on top, you have 3 x"), 2)
    XCTAssertEqual(Speaker.writtenCharacters("e to the 2 x plus 1, end exponent, plus 5"), 7)
    // "over" and "on the bottom" are the fraction bar.
    XCTAssertEqual(Speaker.writtenCharacters("d y over d x"), 5)
    XCTAssertEqual(Speaker.writtenCharacters("on the bottom, you have h"), 2)
    // A part is a whole piece of math, however many words it takes: each factor in its
    // parentheses, never "close parenthesis, times open parenthesis" on its own.
    XCTAssertEqual(
      Speaker.dictationGroups(
        "on top, you have open parenthesis, secant squared w, close parenthesis, times open parenthesis, "
          + "6 minus w cubed, close parenthesis"),
      ["on top, you have open parenthesis, secant squared w, close parenthesis",
       "times open parenthesis, 6 minus w cubed, close parenthesis"])
    // A power stays with what it's on.
    XCTAssertEqual(
      Speaker.dictationGroups("on the bottom, you have open parenthesis, 6 minus w cubed, close parenthesis, squared"),
      ["on the bottom, you have open parenthesis, 6 minus w cubed, close parenthesis, squared"])
    // Words that only say where to write, at the end of a line, stay with the last part.
    XCTAssertEqual(Speaker.dictationGroups("g prime of w, equals a fraction, on top"), ["g prime of w, equals a fraction, on top"])
  }

  func testSpelledLettersAreCounted() {
    XCTAssertEqual(Speaker.writtenCharacters("the letters t a n, w"), 4)
    XCTAssertEqual(Speaker.writtenCharacters("the letters t A n"), 3)
    XCTAssertEqual(Speaker.writtenCharacters("the letters c o s, a small tick"), 3)
  }

  func testSentenceLinesAndPartLabels() {
    XCTAssertEqual(Speaker.penLine(in: "Sentence: capital the radius, period")?.0, .sentence)
    XCTAssertEqual(Speaker.cue(for: .init(kind: .sentence, text: "x", number: 2)), "Start line 2.")
    // A part letter is read as the letter, not "uh".
    XCTAssertEqual(Speaker.problemLabel(in: "Problem: 5, part a"), "5, part A")
    XCTAssertEqual(Speaker.problemLabel(in: "Problem: 15, part b."), "15, part B")
    // Words take longer to write than symbols: every letter counts, "capital" counts none.
    XCTAssertEqual(
      Speaker.sentenceWritingTime("capital the radius is increasing at,"), 0.7 * 23, accuracy: 0.001)
    XCTAssertEqual(Speaker.sentenceWritingTime("f t, slash, s, period."), 0.7 * 9, accuracy: 0.001)
  }

  func testNewNotationCounts() {
    // Only "letter a" is a mark; the "a" starting a shape description isn't.
    XCTAssertEqual(Speaker.writtenCharacters("theta, a 0 with a line across the middle"), 2)
    XCTAssertEqual(Speaker.writtenCharacters("letter a, small raised 2"), 2)
    XCTAssertEqual(Speaker.writtenCharacters("y, prime mark, a small tick at the top right"), 2)
    XCTAssertEqual(Speaker.writtenCharacters("tiny raised 2"), 1)
    XCTAssertEqual(Speaker.writtenCharacters("small lowered b, back up"), 1)
    XCTAssertEqual(Speaker.writtenCharacters("root sign, a check mark with a small 3 tucked in its notch"), 1)
  }

  func testProblemLabels() {
    XCTAssertEqual(Speaker.problemLabel(in: "Problem: 4"), "4")
    XCTAssertEqual(Speaker.problemLabel(in: "problem: number 7."), "number 7")
    XCTAssertNil(Speaker.problemLabel(in: "Problem:"))
    XCTAssertNil(Speaker.problemLabel(in: "Problems are fun"))
  }

  func testCues() {
    XCTAssertEqual(Speaker.cue(for: .init(kind: .write, text: "x", number: 2)), "Start line 2.")
    XCTAssertEqual(
      Speaker.cue(for: .init(kind: .continueLine, text: "x", number: 2)), "Same line.")
    // A line that says where it goes needs no cue.
    XCTAssertEqual(Speaker.cue(for: .init(kind: .continueLine, text: "on the bottom, h", number: 2)), "")
    XCTAssertEqual(Speaker.cue(for: .init(kind: .continueLine, text: "On top, 3 x", number: 2)), "")
    XCTAssertEqual(Speaker.cue(for: .init(kind: .mark, text: "x", number: 2)), "")
  }

  func testLinesSplitIntoWritableParts() {
    // A function stays with what it applies to, and a coefficient with what it multiplies.
    XCTAssertEqual(
      Speaker.dictationGroups("y prime, equals, 6 x, cosine, open paren, 3 x squared, close paren."),
      ["y prime, equals", "6 x, cosine, open paren, 3 x squared, close paren"])
    // A comma inside a number doesn't split it.
    XCTAssertEqual(Speaker.dictationGroups("y prime, equals, 1,000 x squared"), ["y prime, equals", "1,000 x squared"])
    // "end exponent" finishes the power before it; a short line is said in one go.
    XCTAssertEqual(
      Speaker.dictationGroups("e to the 2 x plus 1, end exponent, plus 5"),
      ["e to the 2 x plus 1, end exponent, plus 5"])
    // A shape description stays with the mark it describes, and doesn't count as marks.
    XCTAssertEqual(
      Speaker.dictationGroups("y, prime mark, a small tick at the top right, equals sign, 3, times dot, a small dot at middle height"),
      ["y, prime mark, a small tick at the top right, equals sign, 3", "times dot, a small dot at middle height"])
    XCTAssertEqual(Speaker.dictationGroups(" , ."), [])
  }

  /// Writing pauses come only between whole pieces of math; Claude's other commas are breaths.
  func testWritingPausesFallBetweenWholePiecesOfMath() {
    // Not "7 ... 5 x squared ... plus 2 ... negative 1 ... sine x".
    XCTAssertEqual(
      Speaker.dictationGroups("7 times, open parenthesis, 5 x squared, plus 2, close parenthesis, minus 1, sine x"),
      ["7 times, open parenthesis, 5 x squared, plus 2, close parenthesis", "minus 1, sine x"])
    // A coefficient stays with its variable, and "end exponent" with the power it ends.
    XCTAssertEqual(
      Speaker.dictationGroups(
        "h prime of w equals, negative 40 over 9, w to the negative 13 over 9, end exponent, plus 6 w to the negative 9"),
      ["h prime of w equals", "negative 40 over 9, w to the negative 13 over 9, end exponent",
       "plus 6 w to the negative 9"])
    // A long sum is split before its terms.
    XCTAssertEqual(
      Speaker.dictationGroups("y equals, 3 x to the 4th, minus 5 x cubed, plus 2 x squared, minus 7 x, plus 9"),
      ["y equals, 3 x to the 4th", "minus 5 x cubed, plus 2 x squared", "minus 7 x, plus 9"])
    // A limit stays with "of", and f stays with its argument.
    XCTAssertEqual(
      Speaker.dictationGroups("f prime of x equals, the limit as h approaches 0, of a fraction"),
      ["f prime of x equals", "the limit as h approaches 0, of a fraction"])
    XCTAssertEqual(
      Speaker.dictationGroups("on top, you have f of, open parenthesis, x plus h, close parenthesis, minus f of x"),
      ["on top, you have f of, open parenthesis, x plus h, close parenthesis", "minus f of x"])
    // Parentheses too long to hold in mind are split between their terms, never mid-term,
    // and the power on them stays with the close.
    XCTAssertEqual(
      Speaker.dictationGroups(
        "y equals, 4 times open parenthesis, 3 x squared, plus 2 x, minus 7 x to the 5th, plus 11 x, "
          + "minus 13, close parenthesis, cubed"),
      ["y equals, 4 times open parenthesis, 3 x squared", "plus 2 x, minus 7 x to the 5th", "plus 11 x",
       "minus 13, close parenthesis, cubed"])
    // A Sentence line is words, so any comma between phrases can be a stop.
    XCTAssertEqual(
      Speaker.dictationGroups(
        "capital the radius of the balloon is increasing, at a rate of 3 feet per second, period", isMath: false),
      ["capital the radius of the balloon is increasing", "at a rate of 3 feet per second, period"])
    // The commas stay as breaths inside one utterance, with one writing pause after it.
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak("Problem: 1\nWrite: u equals, 1, plus tangent w")
    XCTAssertEqual(speaker.queued.map(\.text), ["Problem 1.", "Start line 1. u equals, 1, plus tangent w."])
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
      "Write: letter e, start small raised, theta, tiny raised 2, end small raised.",
      "Write: the letters l o g, small lowered b, back up, open parenthesis, x, close parenthesis.",
      "Write: root sign, a check mark with a small 3 tucked in its notch and a line over the top, under the line, x, end root.",
      "Write: 4, point, 9, f t, small raised 3, back down, slash, m i n.",
      "Write: letter e, start small raised, 2 x, plus sign, 1, end small raised.",
      "Problem: 4",
      // The plain wording.
      "Write: u, equals 1, plus the letters t a n, w.",
      "Write: x, raised to the power of 2, right beside that, plus 1.",
      "Write: w, raised to the power of minus 5, slash, 9.",
      "Write: a fraction, on top, 3 x, on the bottom, 2, right beside that, plus 1.",
      "Write: the letters l i m, with h arrow 0 underneath.",
      "Write: d y over d x, equals 3 x over 2, right beside that, plus 1.",
      // The tutor wording.
      "Write: u prime equals secant squared w.",
      "Write: v prime equals negative 3 w squared.",
      "Write: f prime of x equals, the limit as h approaches 0, of a fraction.",
      "Continue: on top, you have f of, open parenthesis, x plus h, close parenthesis, minus f of x.",
      "Write: y equals natural log of x, plus log base 2 of x.",
      "Write: e to the 2 x plus 1, end exponent, plus 5.",
      "Write: the square root of x plus 1, end root, plus 2.",
      "Mark: On line 5, cross out both h's, the h on top and the h on the bottom.",
      "Write: g, prime mark, start an open parenthesis, w, close parenthesis, equals minus 3 w.",
      "Write: a square root sign, under it, x plus 1.",
      "Write: 4 point 9.",
    ] {
      XCTAssertEqual(Speaker.speakable(line), line)
    }
  }

  func testAProblemCanContinueFromALine() {
    XCTAssertEqual(Speaker.startingLine(in: "3, line 4"), 4)
    XCTAssertNil(Speaker.startingLine(in: "3"))
    XCTAssertNil(Speaker.startingLine(in: "5, part A"))
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak("You're on problem 3, line 4.\nProblem: 3, line 4\nWrite: y equals 2\nWrite: y equals 3")
    XCTAssertEqual(
      speaker.queued.map(\.text),
      ["You're on problem 3, line 4.", "Problem 3, line 4.", "Start line 4. y equals 2.", "Start line 5. y equals 3."])
  }

  // MARK: - The built-in voice

  func testNeuralVoiceSpeed() {
    // At the default rate (0.5), sentences are a little slower than the voice's own speed and
    // pen lines slower still; the slider scales both, within a range that sounds natural.
    XCTAssertEqual(NeuralVoice.speed(forRate: 0.5, penLine: false), 0.85, accuracy: 0.001)
    XCTAssertEqual(NeuralVoice.speed(forRate: 0.5, penLine: true), 0.7, accuracy: 0.001)
    XCTAssertEqual(NeuralVoice.speed(forRate: 0.4, penLine: true), 0.56, accuracy: 0.001)
    XCTAssertEqual(NeuralVoice.speed(forRate: 0.1, penLine: true), 0.45, accuracy: 0.001)
    XCTAssertEqual(NeuralVoice.speed(forRate: 0.9, penLine: false), 1.3, accuracy: 0.001)
  }

  func testWithoutTheVoiceFilesAppleVoiceIsUsed() throws {
    // Test builds don't include the voice files, so the setting falls back to Apple's voice.
    try XCTSkipIf(NeuralVoice.isBundled, "this build includes the voice files")
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.useNeuralVoice = true
    XCTAssertFalse(speaker.neuralVoiceActive)
    speaker.speak("Problem: 3")
    XCTAssertEqual(speaker.queued.map(\.text), ["Problem 3."])
    XCTAssertTrue(speaker.isActive)
  }

  func testAzureLineIsOneRequestWithItsPauses() {
    let items = [
      NeuralVoice.Item(text: "Start line 1. u equals 1,", speed: 0.7, pauseAfter: 1.4, token: 0, group: 5),
      NeuralVoice.Item(text: "plus tangent w.", speed: 0.7, pauseAfter: 25, token: 1, group: 5),
    ]
    let ssml = NeuralVoice.ssml(for: items, voice: "en-US-AvaMultilingualNeural")
    XCTAssertTrue(ssml.contains("<voice name=\"en-US-AvaMultilingualNeural\">"))
    // The speed becomes a rate, and the pause between the parts a break inside the request;
    // the last part's pause is played as silence after it.
    XCTAssertTrue(ssml.contains("<prosody rate=\"-30%\">"))
    XCTAssertTrue(ssml.contains("Start line 1. u equals 1,<break time=\"1400ms\"/> plus tangent w."))
    XCTAssertFalse(ssml.contains("25000ms"))
    // A pause over Azure's 20-second limit is several breaks.
    let long = NeuralVoice.ssml(
      for: [
        NeuralVoice.Item(text: "a", speed: 1, pauseAfter: 25, token: 0),
        NeuralVoice.Item(text: "b", speed: 1, pauseAfter: 0, token: 1),
      ], voice: "v")
    XCTAssertTrue(long.contains("<break time=\"20000ms\"/><break time=\"5000ms\"/>"))
    XCTAssertTrue(long.contains("<prosody rate=\"0%\">"))
    // Text is escaped, so "h's" or "<" can't break the request.
    XCTAssertEqual(NeuralVoice.escapeXML("both h's & x < 2"), "both h&apos;s &amp; x &lt; 2")
    XCTAssertEqual(Speaker.azureVoiceName("en-US-AvaMultilingualNeural"), "Ava")
    XCTAssertEqual(Speaker.azureVoiceName("en-US-JennyNeural"), "Jenny")
  }

  func testUnreachableAzureFallsBackToApple() async throws {
    try XCTSkipIf(NeuralVoice.isBundled, "this build includes Heart, which would be used instead")
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.useNeuralVoice = true
    // A region that doesn't exist, so the request fails at once.
    speaker.azureVoice = NeuralVoice.AzureVoice(key: "k", region: "nowhere.invalid", voice: "en-US-AvaMultilingualNeural")
    XCTAssertTrue(speaker.neuralVoiceActive)
    speaker.speak("Problem: 3")
    // Azure fails, there's no Heart, so Apple's voice takes over.
    let fellBack = await waitUntil(20) { !speaker.neuralVoiceActive }
    XCTAssertTrue(fellBack)
    XCTAssertTrue(speaker.isActive)
  }

  func testCheckLinesAreReadBackSmoothly() {
    XCTAssertEqual(Speaker.checkLine(in: "Check: So line 1 reads y equals 2"), "So line 1 reads y equals 2.")
    XCTAssertNil(Speaker.checkLine(in: "Check:"))
    XCTAssertNil(Speaker.checkLine(in: "Checking is fun"))
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak("Problem: 3\nWrite: y equals, 2\nCheck: So line 1 reads y equals 2.\nWrite: y prime equals, 0")
    // The read-back is its own smooth sentence with a short beat after it, and doesn't count
    // as a line: the next Write is line 2.
    XCTAssertEqual(
      speaker.queued.map(\.text),
      ["Problem 3.", "Start line 1. y equals, 2.", "So line 1 reads y equals 2.", "Start line 2. y prime equals, 0."])
    XCTAssertEqual(speaker.queued[2].pause, 0.8, accuracy: 0.001)
  }

  // MARK: - An answer arriving in pieces

  private static let answer = """
    I can see problems 3 and 4.
    Problem: 3
    This is the derivative of x squared.
    You'll write two lines.
    Write: y, equals sign, x, small raised 2
    Write: y, prime mark, a small tick at the top right, equals sign, 2 x
    Continue: plus sign, the letters t a n, x
    Mark: Draw a box around line 2.
    Problem: 4
    Sentence: capital the radius, period
    Done.
    """

  func testPiecesSoundTheSameAsTheWholeAnswer() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.speak(Self.answer)
    let whole = speaker.queued
    XCTAssertGreaterThan(whole.count, 5)
    // Split anywhere, including inside a line and right after a line break.
    for size in [1, 7, 40, 500] {
      speaker.beginAnswer()
      var rest = Substring(Self.answer)
      while !rest.isEmpty {
        speaker.continueAnswer(String(rest.prefix(size)))
        rest = rest.dropFirst(size)
      }
      speaker.finishAnswer()
      XCTAssertEqual(speaker.queued.map(\.text), whole.map(\.text), "pieces of \(size)")
      XCTAssertEqual(speaker.queued.map(\.pause), whole.map(\.pause), "pieces of \(size)")
    }
  }

  func testALineIsSpokenOnlyOnceItIsComplete() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.beginAnswer()
    speaker.continueAnswer("Problem: 3\nWrite: y, equals")
    XCTAssertEqual(speaker.queued.map(\.text), ["Problem 3."])
    speaker.continueAnswer(" sign, 2\n")
    XCTAssertEqual(speaker.queued.map(\.text), ["Problem 3.", "Start line 1. y, equals sign, 2."])
  }

  func testStoppingEndsTheAnswer() {
    let speaker = Speaker()
    speaker.beginAnswer()
    speaker.continueAnswer("Problem: 3\n")
    speaker.stop()
    speaker.continueAnswer("Write: x\n")
    speaker.finishAnswer(notice: "Stop.")
    XCTAssertTrue(speaker.queued.isEmpty)
  }

  func testCutOffNoticeIsSpokenLast() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.beginAnswer()
    speaker.continueAnswer("Problem: 3\nThis is a sum.\nWrite: x, plus")
    speaker.finishAnswer(notice: "Stop. Cut off.")
    XCTAssertEqual(
      speaker.queued.map(\.text), ["Problem 3.", "This is a sum.", "Start line 1. x, plus.", "Stop. Cut off."])
  }

  func testANoticeDuringAnAnswerWaitsForTheEnd() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.beginAnswer()
    speaker.continueAnswer("Problem: 3\n")
    // A notice that can wait is said after the answer, not instead of it.
    speaker.announce("Glasses session ended.", ifBusy: .after)
    // One that only matters when nothing is being said is dropped.
    speaker.announce("Still working on the last one.", ifBusy: .skip)
    speaker.continueAnswer("Write: x\n")
    speaker.finishAnswer()
    XCTAssertEqual(speaker.queued.map(\.text), ["Problem 3.", "Start line 1. x.", "Glasses session ended."])
  }

  func testANoticeWithNothingBeingSaidIsSpokenRightAway() {
    let speaker = Speaker()
    defer { speaker.stop() }
    speaker.announce("Still working.", ifBusy: .skip)
    XCTAssertEqual(speaker.queued.map(\.text), ["Still working."])
  }

  func testCutOffNotices() {
    XCTAssertEqual(
      Speaker.cutOffNotice(.ranOut, answer: "I can see problems 4 and 5.\nProblem: 4\nWrite: x\nProblem: 5, part a\nWrite: y"),
      "Stop. The answer ran out of room partway through problem 5, part A, so its last line may be unfinished. "
        + "Take a new photo of problem 5, part A and any after it.")
    XCTAssertEqual(
      Speaker.cutOffNotice(.dropped, answer: "I can see problem 2."),
      "Stop. The connection dropped before the first problem. Take the photo again.")
    XCTAssertTrue(Speaker.cutOffNotice(.stopped, answer: "Problem: 7").hasPrefix("Stop. The answer stopped partway"))
  }
}
