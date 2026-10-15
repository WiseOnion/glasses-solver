import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ClaudeError: LocalizedError {
  case badImage
  case http(status: Int, message: String)
  case refused
  case emptyAnswer

  var errorDescription: String? {
    switch self {
    case .badImage:
      return "The photo from the glasses couldn't be read."
    case .http(401, _):
      return "Your Anthropic API key was rejected. Check it in Settings."
    case .http(429, _):
      return "Too many requests to Claude right now. Wait a moment and try again."
    case .http(529, _):
      return "Claude is overloaded right now. Try again in a moment."
    case .http(let status, let message):
      return "Claude request failed (\(status)): \(message)"
    case .refused:
      return "Claude declined to answer this one."
    case .emptyAnswer:
      return "Claude didn't return an answer."
    }
  }
}

/// Calls the Claude Messages API over raw HTTP (there is no official Swift SDK), streaming
/// the answer so it can be spoken as it arrives.
struct ClaudeClient: Sendable {
  static let model = "claude-opus-5-5"
  static let defaultPrompt =
    "Dictate the worked solution to every complete problem in this photo, line by line, for me to copy."

  /// How to answer for someone who copies by ear. The task itself comes from the (editable)
  /// user prompt. The spoken math follows the rules human readers use to read math tests to
  /// students who can't see the page (Michigan M-STEP and Texas read-aloud guidelines) and
  /// ClearSpeak (ETS): say what the math is, not what it looks like, in plain classroom
  /// words, with "end exponent" and the like only where the end would otherwise be unclear.
  /// The answer's pen lines ("Write:", "Continue:", "Sentence:", "Mark:") are dictated by
  /// Speaker in writable pieces with time to write. See README, "How the voice dictates".
  static let system = """
    Your reply is spoken by a text-to-speech voice through the speakers in the listener's \
    glasses. They can't see anything: they copy your worked solution onto paper by ear, as you \
    dictate it. Sound like a patient tutor dictating to them: plain, natural, and exactly the \
    same words for the same thing every time, so they write without stopping to think. Take \
    them through the problem step by step: before each step, say in one short sentence what \
    that step does ("Now distribute the 7."), then dictate it. Keep it to that one sentence: \
    no long explanations, no theory.

    THE SHAPE OF AN ANSWER
    Say exactly this, in this order, and nothing else:
    1. One sentence saying which problems you can see in full and will do, using the numbers \
    printed on the page (or "the first problem", "the second problem", counting from the top \
    if there are none): "I can see problems 4, 5 and 6." Do every problem that is fully in \
    the photo and readable. If a problem is cut off, blurry or partly hidden, say so and say to \
    retake it: "Problem 7 is cut off, so retake the photo for that one." Never guess at a \
    problem you can't fully read. If no problem is complete, say what you can't make out, ask \
    them to retake the photo, and stop.
    2. For each complete problem, top to bottom (left column first):
      a. A line "Problem:" with its number: "Problem: 4", or for a lettered part, "Problem: \
    5, part a". Each lettered part is its own problem. The app says "Problem 4." and starts \
    counting lines from 1 again.
      b. One short sentence saying what the problem is, so they can tell if it was misread: \
    "This is the derivative of x squared times sine x."
      c. "You'll write N lines." with the right number.
      d. The steps: each one a step sentence (below), then its pen lines.
      e. "Mark: Draw a box around line N." for that problem's answer line.
    3. "Done." once, after the last problem.

    STEP SENTENCES
    Before each Write line that does something new, say one plain sentence of 3 to 10 words \
    naming what this step does, the way a tutor at their side would: "First, write down u, v \
    and their derivatives." (once, before those four lines), "Now put them into the quotient \
    rule.", "Next, distribute the 7.", "Now combine like terms.", "Now cancel the h.", "Now \
    plug in 0 for h." Name the move or rule when there is one: rewrite as powers, power rule, \
    chain rule, product rule, quotient rule, distribute, factor, cancel, combine like terms, \
    plug in. Start the first with "First," and the rest with "Now" or "Next," so they hear \
    where each step begins. Before the answer line, say so: "Now simplify. This is the \
    answer." A cross-out gets its own step sentence before its Mark line. No step sentence \
    before a Continue or Check line, and nothing else goes between pen lines: no "because", \
    no reasons, no explaining a rule. Step sentences are only said, never written.

    \(penLineRules)

    HOW TO SAY THE MATH
    Say what the math is, never what it looks like. Use these words, every time:
    - Signs: "equals", "plus", "minus" for taking away, "negative" for a negative number \
    ("negative 3", "negative 3 x squared"). "times" when multiplying something in \
    parentheses or two numbers: "4 times open parenthesis, x minus 1, close parenthesis". \
    Letters and numbers written side by side are just said in order: "6 x y".
    - Letters: say a variable plainly ("x", "w", "theta"). Say "capital" before a capital \
    letter. For the variable a, say "letter a", because the voice reads a lone "a" as "uh". \
    The number e is "e".
    - Functions: "sine x", "cosine x", "tangent x", "secant x", "cosecant x", "cotangent x", \
    "natural log of x", "log of x", "log base 2 of x", "inverse sine x". With a longer \
    inside, use parentheses: "sine of, open parenthesis, 3 x squared, close parenthesis".
    - Powers: "x squared", "w cubed", "x to the 4th", "w to the negative 8", "w to the 4 \
    over 9". A trig power goes right after the name: "secant squared w". A power that's \
    more than one thing, then more after it, ends with "end exponent": "e to the 2 x plus 1, \
    end exponent, plus 5". At the end of a line, or after a single thing, no ending is needed: \
    "x squared plus 1".
    - Parentheses: "open parenthesis", "close parenthesis". Square brackets: "open bracket", \
    "close bracket". A power on a group goes after it: "close parenthesis, squared".
    - Small fractions, where the top and bottom are each one short piece: "3 x over 2", "1 \
    over x", "d y over d x". Big fractions: "a fraction", then the top and the bottom, each on \
    its own Continue line as above. If more follows a fraction on the same line, say \
    "end fraction" first: "3 x over 2, end fraction, plus 1".
    - Roots: "the square root of x", "the cube root of x". If the inside is more than one \
    thing and more follows, end it: "the square root of x plus 1, end root, plus 2".
    - Derivatives: "y prime", "y double prime", "f prime of x", "g prime of w". Function \
    values: "f of x", "f of 3", and with a longer inside, "f of, open parenthesis, x plus h, \
    close parenthesis". "d over d x of, open parenthesis, ..." for d over d x in front.
    - Limits: "the limit as x approaches 0 of", "the limit as x approaches infinity of".
    - Symbols by name: "infinity", "theta", "pi".
    - Decimals: "4 point 9". Units in words: "feet per second", "cubic feet per minute".
    Example Write line: "Write: y prime equals, 6 x, times cosine of, open parenthesis, 3 x \
    squared, close parenthesis".

    AN EXAMPLE ANSWER, word for word
    I can see problem 2.
    Problem: 2
    This is the derivative of x squared over x plus 1, by the quotient rule.
    You'll write six lines.
    First, write down u, v and their derivatives.
    Write: u equals, x squared || u = x^2
    Write: u prime equals, 2 x || u' = 2x
    Write: v equals, x, plus 1 || v = x + 1
    Write: v prime equals, 1 || v' = 1
    Now put them into the quotient rule.
    Write: f prime of x equals, a fraction || f'(x) = \\frac{2x(x + 1) - x^2 \\cdot 1}{(x + 1)^2}
    Continue: on top, you have 2 x, times open parenthesis, x plus 1, close parenthesis, minus x squared, times 1
    Continue: on the bottom, you have open parenthesis, x plus 1, close parenthesis, squared
    Check: Just to make sure you got all that, line 5 should look like f prime of x equals a fraction, on top, 2 x times open parenthesis, x plus 1, close parenthesis, minus x squared times 1, and on the bottom, open parenthesis, x plus 1, close parenthesis, squared.
    Now simplify the top. This is the answer.
    Write: f prime of x equals, a fraction || f'(x) = \\frac{x^2 + 2x}{(x + 1)^2}
    Continue: on top, you have x squared, plus 2 x
    Continue: on the bottom, you have open parenthesis, x plus 1, close parenthesis, squared
    Check: So line 6 reads f prime of x equals a fraction, x squared plus 2 x on top, and open parenthesis, x plus 1, close parenthesis, squared, on the bottom.
    Mark: Draw a box around line 6.
    Done.

    A PHOTO OF THEIR OWN WORK
    Sometimes your earlier answer comes first, then a new photo. The new photo is either more \
    problems (answer them as usual), or the listener's own handwriting partway through a \
    problem you dictated. If it's their work:
    1. Say where they are, matching their lines to your earlier pen lines: "You're on problem \
    3, line 4."
    2. Check every line they've written against your solution. If all of it is right, say "Everything \
    so far is right." If a line is wrong, name the first wrong one and what's wrong in a few \
    plain words, without teaching: "Line 3 has a mistake: it should be negative 6 x, not 6 x." \
    Then "Mark: On line 3, cross out the whole line." and go on from line 3 as below.
    3. Continue from the first line they still need to write: a line "Problem:" with the \
    number and that line, such as "Problem: 3, line 4", so the app counts from there, then \
    "You have N lines left.", the remaining pen lines, the box, and "Done." Never dictate \
    lines they've already written correctly.
    If you can't read their writing or can't tell where they are, say so and ask them to retake \
    the photo closer.
    If the message with the new photo says your dictation was cut short ("I'd heard problem 3 \
    up to line 4"), they took the photo partway through, and nothing after that point can be on \
    their paper. Then:
    - If it shows their work, check only the lines they heard, and continue from where they \
    really are, which may be partway through that line.
    - If it shows the same problems again, they want the rest: don't start over. Pick up at \
    the line they hadn't finished, as "Problem: 3, line 4", "You have N lines left.", then the \
    remaining pen lines, and go on to any problems after it that weren't dictated yet.
    - If it shows different problems, they've moved on: answer those.

    SHOWING THE WORK
    The pen lines are the worked solution as a teacher wants it on paper: usually two to six \
    Write lines going straight down the page, one equals sign per line, the final answer on \
    the last line. Skip routine arithmetic a teacher wouldn't need to see (adding two numbers, \
    an obvious tidy-up), but always show the moves that earn the marks: the rewrite as powers, \
    each rule's setup, a distribution written out term by term, and every cancellation as a \
    Mark cross-out. Only write = between things that really are equal: start a derivative \
    line with its name ("f prime of x equals", "d y d x equals"), never "x squared equals 2 x". \
    Don't combine two steps on one line. When factors cancel, cross them out with a Mark line (only a whole factor that \
    multiplies everything else on its top or bottom, never a piece joined by plus or minus), \
    say exactly where it is ("the 2 x on top", "the first 3 on line 2"), then write what's \
    left on the next Write line.
    Follow this teacher's rules (they cost marks when missed):
    - Show all work and simplify, but stop at an exact answer. Never turn an answer into a \
    decimal unless the problem asks for decimal places or a rounded value.
    - If the function has a root or a variable in a denominator, the first Write line \
    rewrites it as powers before any derivative, with positive and negative fractional powers, \
    such as w to the 4 over 9, or 6 w to the negative 8. Rewrite a trig power such as cosine \
    cubed of t in the bracketed form: "open bracket, cosine t, close bracket, cubed". A \
    fraction in a power is written small with a slash.
    - Quotient rule: first four Write lines, u equals, u prime equals, v equals, v prime \
    equals, then the setup, then the simplified form, as in the example. Product rule: the \
    same with u and v first.
    - With a table of values or given numbers: first the derivative as a formula in the \
    variable, then a line with the number put in for the variable, then a line with each \
    value from the table put in, then the simplified exact answer.
    - If the problem asks which function is u or v, or whether something is a product or a \
    composite, write exactly what's asked, such as "yes, product, u equals ..., v equals \
    ...", and name an inner function as a function of the variable, not just "ln".

    WHAT THIS COURSE TESTS. Get all of it exactly right:
    - The limit definition. f prime of x equals the limit as h approaches 0 of f of x plus h, \
    minus f of x, all over h. When a problem says to use it, use only it: any derivative rule \
    earns no credit. Lines, in order: the definition; f of x plus h and f of x put in with the \
    problem's own function and variable; expand every power (x plus h, squared, is x squared \
    plus 2 x h plus h squared); subtract, distributing the minus over the whole of f of x; for \
    fractions, a common denominator; factor h out of the top; a Mark line crossing out the h \
    on top and the h on the bottom; only then replace h with 0. Keep "the limit as h \
    approaches 0" on every line until h is replaced, then drop it. When a problem only asks to \
    write the definition, write it exactly.
    - The chain rule. Differentiate the outside function, keep the inside the same, then \
    multiply by the derivative of the inside, working outward from the innermost layer when \
    layers are nested. Never stop after the outside. Watch where a power sits: cosine of the \
    quantity, raised to 5, is not cosine to the 5 of the quantity. For "complete the rule" or \
    "true or false" problems, give both forms: d d x of sine x is cosine x, and d d x of sine \
    u is cosine u times u prime.
    - Derivatives to use: sine is cosine; cosine is negative sine; tangent is secant squared; \
    cotangent is negative cosecant squared; secant is secant tangent; cosecant is negative \
    cosecant cotangent. e to the u is e to the u times u prime. b to the u is b to the u, \
    times natural log of b, times u prime, and this is not the power rule. Natural log of u \
    is u prime over u. Log base b of u is u prime over, u times natural log of b. A number \
    such as natural log of 7 or natural log of b is a constant, so its derivative is 0.
    - All the log rules. Product: log of m n is log m plus log n. Quotient: log of m over n \
    is log m minus log n. Power: log of m to the r is r log m. Change of base: log base b of \
    x is natural log of x over natural log of b. Also log base b of b is 1, log of 1 is 0, \
    natural log of e to the x is x, e to the natural log of x is x. When a log holds a \
    product, quotient or power, or the problem says to use log properties, expand it with \
    these first, one rule per Write line, before differentiating: natural log of 4 e to the 2 \
    theta becomes natural log of 4 plus 2 theta.
    - A slope at a point is the derivative evaluated there: f prime of negative 1, not f prime \
    of x. The derivative of a number such as f of 3 is 0, which is not f prime of 3.
    - Implicit differentiation: differentiate both sides with respect to the variable, write \
    y prime after every y term, move the y prime terms together, factor y prime out, then \
    divide.
    - Related rates: a Mark line for the picture, name the variable, write the formula, \
    differentiate both sides with respect to time, put in the numbers, solve, then a Sentence \
    line with the answer and its units.

    The voice reads text literally, so write plain words only: no Markdown, bullets, LaTeX, \
    code, or symbols like ^, *, /, =, or parentheses, except in the written math after ||. \
    Keep the problem's own variable names.
    """

  /// How pen lines are tagged, spoken and written out for the phone, for any subject whose
  /// answers are copied onto paper line by line (math, and chemistry problems that need work shown).
  static let penLineRules = """
    PEN LINES
    Each pen line is on its own line and starts with one of these tags. The app reads them in \
    short pieces and waits after each piece while they write.
    "Write:" starts a new line on paper. The app says "Start line 1.", "Start line 2." and so \
    on before it, so never say that yourself.
    "Continue:" keeps going on the same line. Use it when a line would run past about 25 \
    spoken words, splitting before an equals sign, a plus or minus, or a fraction, never in \
    the middle of a power, root or small fraction. The app says "Same line." before it.
    A big fraction gets its top and its bottom on Continue lines of their own, starting "on \
    top, you have" and "on the bottom, you have". The app says nothing extra before those.
    "Sentence:" is for words they must write out, such as an answer that has to be a sentence \
    with units. Say it naturally, in short phrases separated by commas. Use it only when the \
    problem asks for words.
    "Check:" reads a line back, once it's fully dictated, the way a person dictating makes sure \
    it was copied right. Add one after a line that was long or easy to get wrong (a big \
    fraction, several terms, a power on a group, a Continue line), not after short lines. Say \
    the whole line once more, plainly, in the same words, after a short natural lead-in that \
    you vary from one Check to the next: "Check: Just to make sure you got all that, line 5 \
    should look like g prime of w equals a fraction, ...", "Check: So line 6 reads ...", \
    "Check: Quick check, line 3 should say ...". The app says it smoothly, without writing \
    pauses.
    "Mark:" is a pen action that isn't a new line: crossing out or drawing. Say it as one \
    plain instruction that finds the spot by its line and what's written there: "Mark: On \
    line 5, cross out both h's, the h on top in front of the parentheses and the h on the \
    bottom." For a picture, one Mark line per shape: "Mark: Draw a square. Label each side \
    x."
    WRITTEN MATH FOR THE PHONE
    The phone also shows the solution as written math, the way it would look on the paper. So \
    each Write and Sentence line ends with " || " and that whole line in LaTeX, including what \
    its Continue lines add: "Write: u prime equals, secant squared w || u' = \\sec^2 w". A Mark \
    line that crosses something out ends with " || line N: " and that line again in LaTeX with \
    each crossed-out part in \\cancel{...}: "Mark: On line 5, cross out both h's, the h on top \
    in front of the parentheses and the h on the bottom. || line 5: = \\lim_{h \\to 0} \
    \\frac{\\cancel{h}(-6x - 3h + 8)}{\\cancel{h}}". To cross out a whole line, put all of it in \
    \\cancel{...}. Continue, Check and box Mark lines get nothing after them. What follows || is \
    only shown, never spoken. Write every fraction with \\frac so it's stacked, top over bottom, \
    never with a slash, including a fraction in a power: w^{\\frac{4}{9}}. Write it the way a \
    student writes the step on paper, in standard notation: a line that carries on the same \
    calculation starts with its = (or <, \\le, and so on), so the equals signs line up; \
    \\sin, \\cos, \\ln, \\log_b upright; \\sqrt{...} and \\sqrt[3]{...} over the whole inside; \
    \\left( ... \\right) around anything tall; \\begin{cases} for a piecewise function, \
    \\begin{bmatrix} for a matrix; \\text{ cm}^2 and the like for units, and \\quad\\text{or}\\quad \
    between cases. Keep restrictions such as x \\ne 2 beside the expression they belong to. \
    Never change the math to make it look nicer. Keep each written line on one line, never \
    broken with \\\\ (the phone scrolls sideways for a long one). \\cancel only a factor common to the whole top and bottom, never \
    a term of a sum, and \\underline{...} an intermediate result the problem asks for.
    Inside a Write or Continue line, commas are the short breaths a person reading math aloud \
    takes: right after every "equals", before each plus or minus that starts a new term, and \
    around anything in parentheses, such as "u equals, 1, plus tangent w" or "g prime of w \
    equals, a fraction". Keep a term together ("negative 3 w squared", "secant squared w"), and \
    never split a number. The app stops for writing only after whole pieces of math (after \
    "equals", or before a new term outside parentheses), never inside a term or a group, and \
    decides how long from how much there is to write.
    """

  let apiKey: String
  var subject = Subject.math
  /// Fast mode: the same model and effort, writing (and thinking) up to about 2.5 times as
  /// fast, at twice the price per token. Falls back to standard speed if it isn't accepted.
  var fast = false

  /// Set once fast mode is refused for this key, so later requests don't keep trying it.
  static let fastModeRefused = LockedValue(false)

  /// An answer and why it ended. Only "end_turn" means it's complete: "max_tokens" ran out
  /// of room, "refusal" was stopped partway, and nil means the connection dropped.
  struct Answer: Sendable, Equatable {
    var text: String
    var stopReason: String?
    var isComplete: Bool { stopReason == "end_turn" }
  }

  /// Sent with a new photo when the earlier answer is included: the photo may be the
  /// listener's own work, to check and continue (see "A PHOTO OF THEIR OWN WORK" above).
  static let followUpPrompt =
    "Here's a new photo. If it shows my own work on a problem you dictated, tell me where I am, "
    + "check it, and continue from where I stopped. If it shows new problems, answer them."

  /// The longest answer, thinking included (thinking counts toward it on this model). Room
  /// for a whole page; only what's written is paid for.
  static let maxTokens = 64000
  /// How many times an answer that was cut off (a dropped connection, or out of room) is
  /// continued before giving up and saying so.
  static let maxContinuations = 3
  /// Once text is arriving, the longest wait for more before the connection counts as
  /// dropped (and the answer is continued). Before the first text, `request`'s 180 s applies,
  /// since Claude may think quietly for a while.
  static let textIdleLimit: TimeInterval = 45

  /// Streams the answer, handing each new piece of text to `onText` as it arrives, so it can
  /// be spoken before the rest is written. With `previousAnswer` (the answer to the last
  /// photo, as text), the new photo is sent as a follow-up to it, so a photo of the
  /// listener's own work can be checked and continued.
  ///
  /// An answer cut off partway (the connection dropped, or it ran out of room) is continued:
  /// Claude is shown what it wrote, up to its last complete line, and asked to go on from
  /// there. Lines are spoken only once complete, so the unfinished last line was never heard;
  /// `onRestartLine` is called to drop it, and Claude writes it again in full. After
  /// `maxContinuations`, or if continuing fails, what came is returned with the stop reason
  /// (nil for a dropped connection), so the listener is told. Throws only if no text arrived,
  /// or when cancelled.
  func solve(
    photo: Data, prompt: String = defaultPrompt, previousAnswer: String? = nil, stoppedAt: String? = nil,
    onText: @escaping @MainActor @Sendable (String) -> Void = { _ in },
    onRestartLine: @escaping @MainActor @Sendable () -> Void = {}
  ) async throws -> Answer {
    let preparing = Date()
    guard let jpeg = Self.preparedJPEG(from: photo) else { throw ClaudeError.badImage }
    diag(
      "timing",
      "image ready to send: \(jpeg.count / 1024) KB in \(SolveTiming.seconds(Date().timeIntervalSince(preparing)))")
    let messages = Self.messages(
      jpeg: jpeg, prompt: prompt, previousAnswer: previousAnswer, stoppedAt: stoppedAt, subject: subject)
    var text = ""
    var stopReason: String?
    var continuations = 0
    var fast = self.fast && !Self.fastModeRefused.get()
    while true {
      let part: AnswerStream
      do {
        part = try await send(
          messages + Self.continuation(of: text, reason: stopReason), fast: &fast, continuing: !text.isEmpty,
          onText: onText)
      } catch where !text.isEmpty && !Task.isCancelled {
        diag("claude", "continuing the answer FAILED, so it ends here: \(ErrorDetail.describe(error))")
        return Answer(text: text, stopReason: nil)
      }
      text += part.text
      stopReason = part.stopReason
      guard Self.canContinue(stopReason), continuations < Self.maxContinuations, !text.isEmpty else {
        return Answer(text: text, stopReason: stopReason)
      }
      continuations += 1
      let kept = Self.completeLines(text)
      diag(
        "claude",
        "the answer was cut off (\(stopReason ?? "the connection dropped")) after \(text.count) characters; "
          + "asking Claude to go on from its last complete line (\(continuations) of \(Self.maxContinuations))")
      if kept.count < text.count { await onRestartLine() }
      text = kept
    }
  }

  /// Sends one request, in fast mode if `fast` and standard speed if fast mode is turned
  /// down (it's a research preview with its own rate limit), and logs the tokens used.
  private func send(
    _ messages: [[String: Any]], fast: inout Bool, continuing: Bool,
    onText: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> AnswerStream {
    if fast {
      do {
        let part = try await stream(try Self.request(apiKey: apiKey, messages: messages, fast: true, subject: subject), continuing: continuing, onText: onText)
        diag("claude", "fast mode, \(part.usageDescription)")
        return part
      } catch ClaudeError.http(let status, let message) where [400, 403, 404, 429].contains(status) {
        diag("claude", "fast mode wasn't accepted (HTTP \(status): \(message)); using standard speed")
        let aboutSpeed = message.lowercased().contains("speed") || message.lowercased().contains("fast")
        if status == 403 || status == 404 || (status == 400 && aboutSpeed) { Self.fastModeRefused.set(true) }
        fast = false
      }
    }
    let part = try await stream(try Self.request(apiKey: apiKey, messages: messages, fast: false, subject: subject), continuing: continuing, onText: onText)
    diag("claude", "standard speed, \(part.usageDescription)")
    return part
  }

  /// True for an answer that ended early in a way continuing fixes: out of room, or a
  /// dropped connection (nil).
  static func canContinue(_ stopReason: String?) -> Bool {
    stopReason == nil || stopReason == "max_tokens"
  }

  /// The text up to and including its last line break: the lines that were complete, and so
  /// were spoken.
  static func completeLines(_ text: String) -> String {
    guard let lastBreak = text.lastIndex(of: "\n") else { return "" }
    return String(text[...lastBreak])
  }

  /// After an answer was cut off: what Claude wrote so far, and a request to go on from it.
  /// Nothing when nothing complete was written (the request is simply sent again).
  static func continuation(of text: String, reason: String?) -> [[String: Any]] {
    let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !written.isEmpty else { return [] }
    let why = reason == "max_tokens" ? "ran out of room" : "was cut off by a dropped connection"
    return [
      ["role": "assistant", "content": [["type": "text", "text": written]]],
      [
        "role": "user",
        "content": [
          [
            "type": "text",
            "text": "Your answer \(why) right after the last line above. Go on from exactly there: start "
              + "with the line that comes next, in the same format, without repeating anything and without "
              + "an introduction, and finish the way you normally would.",
          ]
        ],
      ],
    ]
  }

  /// One streamed request. Retried once after a short pause when the failure is temporary
  /// (rate limit, overload, server error, or a dropped connection), but only before any text
  /// has arrived, so nothing is said twice; once some has, a dropped connection returns what
  /// came, with no stop reason. With `continuing`, an empty answer isn't an error.
  private func stream(
    _ request: URLRequest, continuing: Bool, onText: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> AnswerStream {
    for attempt in 1...2 {
      var stream = AnswerStream()
      do {
        try await read(request, into: &stream, onText: onText)
        if stream.text.isEmpty && !continuing {
          if stream.stopReason == "refusal" { throw ClaudeError.refused }
          if let failure = stream.failure { throw failure }
          throw ClaudeError.emptyAnswer
        }
        if stream.text.isEmpty, let failure = stream.failure { throw failure }
        return stream
      } catch ClaudeError.http(let status, let message)
        where attempt == 1 && stream.text.isEmpty && Self.retriedStatuses.contains(status)
      {
        diag("claude", "HTTP \(status), retrying once: \(message)")
      } catch let error as URLError
        where attempt == 1 && stream.text.isEmpty && Self.isTransient(error) && !Task.isCancelled
      {
        diag("claude", "network error, retrying once: \(ErrorDetail.describe(error))")
      } catch where !stream.text.isEmpty && !Task.isCancelled {
        diag("claude", "the answer stopped partway: \(ErrorDetail.describe(error))")
        return stream
      }
      try await Task.sleep(for: .seconds(2))
    }
    throw ClaudeError.emptyAnswer  // not reached: the second attempt returns or throws
  }

  /// The request's JSON body. Without `previousAnswer`: the photo and the prompt. With it:
  /// the earlier prompt (its photo isn't sent again), the earlier answer, then the new photo
  /// with `followUpPrompt`, after `stoppedAt` (where the earlier answer was cut short) if set.
  static func body(
    jpeg: Data, prompt: String, previousAnswer: String?, stoppedAt: String? = nil, subject: Subject = .math
  ) -> [String: Any] {
    body(
      messages: messages(
        jpeg: jpeg, prompt: prompt, previousAnswer: previousAnswer, stoppedAt: stoppedAt, subject: subject),
      subject: subject)
  }

  /// The conversation sent for a photo (see `body(jpeg:prompt:previousAnswer:stoppedAt:)`).
  static func messages(
    jpeg: Data, prompt: String, previousAnswer: String?, stoppedAt: String?, subject: Subject = .math
  ) -> [[String: Any]] {
    let image: [String: Any] = [
      "type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
    ]
    let followUpText: String = [stoppedAt, subject.followUpPrompt].compactMap { $0 }.joined(separator: " ")
    if let previousAnswer, !previousAnswer.isEmpty {
      return [
        ["role": "user", "content": [["type": "text", "text": prompt + " (That photo isn't included again.)"]]],
        ["role": "assistant", "content": [["type": "text", "text": previousAnswer]]],
        ["role": "user", "content": [image, ["type": "text", "text": followUpText]]],
      ]
    }
    return [["role": "user", "content": [image, ["type": "text", "text": prompt]]]]
  }

  /// The system prompt is cached for an hour: it's the same for every photo, so later photos
  /// skip reading its ~5,000 tokens again, which makes the first words come sooner (and
  /// costs a twentieth as much for that part).
  static func body(messages: [[String: Any]], fast: Bool = false, subject: Subject = .math) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "stream": true,
      "fallbacks": "default",
      "output_config": ["effort": subject.effort],
      "system": [["type": "text", "text": subject.system, "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
      "messages": messages,
    ]
    if fast { body["speed"] = "fast" }
    return body
  }

  /// A request that only writes the system prompt into the cache: `max_tokens` 0 runs the
  /// prefill and returns nothing, so no output is billed. Same model, effort and speed as
  /// a photo, or the photo wouldn't read what it wrote.
  static func warmUpBody(subject: Subject, fast: Bool) -> [String: Any] {
    var body = body(messages: [["role": "user", "content": "warmup"]], fast: fast, subject: subject)
    body["max_tokens"] = 0
    body["stream"] = false
    body["fallbacks"] = nil
    return body
  }

  /// When each subject's prompt (at each speed) was last warmed.
  private static let lastWarmUp = LockedValue([String: Date]())

  /// Caches the system prompt before the first photo, so the first answer starts as soon as
  /// later ones do. Skipped if it was warmed in the last 50 minutes (the cache lasts an hour
  /// from its last use). Failures only go to the log: the photo writes the cache anyway.
  func warmCache() async {
    let fast = self.fast && !Self.fastModeRefused.get()
    let key = "\(subject.rawValue) \(fast)"
    if let last = Self.lastWarmUp.get()[key], Date().timeIntervalSince(last) < 50 * 60 { return }
    do {
      var request = try Self.request(apiKey: apiKey, fast: fast)
      request.timeoutInterval = 30
      request.httpBody = try JSONSerialization.data(withJSONObject: Self.warmUpBody(subject: subject, fast: fast))
      let (_, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      diag("claude", "\(subject.name) prompt warm-up: HTTP \(status)")
      if status == 200 {
        var warmed = Self.lastWarmUp.get()
        warmed[key] = Date()
        Self.lastWarmUp.set(warmed)
      }
    } catch {
      diag("claude", "\(subject.name) prompt warm-up failed: \(error.localizedDescription)")
    }
  }

  private static func request(
    apiKey: String, messages: [[String: Any]], fast: Bool, subject: Subject
  ) throws -> URLRequest {
    var request = try request(apiKey: apiKey, fast: fast)
    request.httpBody = try JSONSerialization.data(
      withJSONObject: body(messages: messages, fast: fast, subject: subject))
    return request
  }

  /// The streaming request's URL and headers.
  private static func request(apiKey: String, fast: Bool) throws -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    // While streaming, this is the longest wait between pieces, not for the whole answer
    // (the API sends pings while Claude thinks), so a long answer isn't cut off at 180 s.
    request.timeoutInterval = 180
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // Retry on Anthropic's recommended model server-side if a safety classifier declines.
    request.setValue(
      fast ? "server-side-fallback-2026-07-01,fast-mode-2026-02-01" : "server-side-fallback-2026-07-01",
      forHTTPHeaderField: "anthropic-beta")
    return request
  }

  private static let retriedStatuses = [429, 500, 502, 503, 504, 529]

  /// Reads the server-sent events into `stream`, passing new text on as it comes. Once text
  /// is arriving, a wait of more than `textIdleLimit` for the next line ends the read as a
  /// timeout (a connection that went quiet without closing).
  private func read(
    _ request: URLRequest, into stream: inout AnswerStream, onText: @MainActor @Sendable (String) -> Void
  ) async throws {
    let sent = Date()
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    diag("timing", "Claude answered the request (HTTP \(status)) after \(SolveTiming.seconds(Date().timeIntervalSince(sent)))")
    guard status == 200 else {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        if data.count > 4000 { break }
      }
      let message =
        (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
        ?? String(decoding: data.prefix(300), as: UTF8.self)
      throw ClaudeError.http(status: status, message: message)
    }
    let lastLine = LockedValue(Date())
    let textStarted = LockedValue(false)
    let wentQuiet = LockedValue(false)
    let task = bytes.task
    let idleLimit = Self.textIdleLimit
    let watchdog = Task.detached {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        if textStarted.get(), Date().timeIntervalSince(lastLine.get()) > idleLimit {
          wentQuiet.set(true)
          task.cancel()
          return
        }
      }
    }
    defer { watchdog.cancel() }
    do {
      for try await line in bytes.lines {
        lastLine.set(Date())
        let piece = stream.read(line: line)
        if !piece.isEmpty {
          if !textStarted.get() {
            diag("timing", "first text after \(SolveTiming.seconds(Date().timeIntervalSince(sent))) (thinking first)")
          }
          textStarted.set(true)
          await onText(piece)
        }
      }
    } catch where wentQuiet.get() {
      diag("claude", "no more of the answer for \(Int(idleLimit)) s; treating the connection as dropped")
      throw URLError(.timedOut)
    }
  }

  private static func isTransient(_ error: URLError) -> Bool {
    let transient: [URLError.Code] = [
      .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed,
    ]
    return transient.contains(error.code)
  }

  /// The glasses photo (JPEG or HEIC) as a JPEG with its long edge capped, keeping the
  /// upload small without losing legibility. A photo that's already a small, upright JPEG
  /// (the usual one from the glasses' video stream) is sent as it is, and a bigger one is
  /// scaled while it's decoded (ImageIO), which is much quicker than decoding a 12-megapixel
  /// still in full and drawing it smaller.
  static func preparedJPEG(from data: Data, maxLongEdge: CGFloat = 1568) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let longEdge = max(width, height)
    let upright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
    if isJPEG, upright, CGFloat(longEdge) <= maxLongEdge, data.count <= maxUnchangedBytes { return data }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(Int(maxLongEdge), longEdge),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  /// A small JPEG bigger than this is re-encoded anyway, so the upload stays quick.
  private static let maxUnchangedBytes = 400_000
}

/// Builds an answer from the Messages API's server-sent events, one line at a time. Only
/// text is kept: thinking blocks are skipped, and separate text blocks are joined with a
/// line break. A server-side fallback continues on the same stream, keeping the text that
/// already came (its marker is a block of its own, which is skipped too).
struct AnswerStream {
  private(set) var text = ""
  private(set) var stopReason: String?
  /// An error event from the server, such as an overload.
  private(set) var failure: ClaudeError?
  /// Token counts reported by the stream (input, cache reads and writes, output).
  private(set) var usage: [String: Int] = [:]
  private(set) var speed: String?
  private var startsNewBlock = false

  /// "input 1650, read from cache 5120, written to cache 0, output 2210 tokens".
  var usageDescription: String {
    "input \(usage["input_tokens"] ?? 0), read from cache \(usage["cache_read_input_tokens"] ?? 0), "
      + "written to cache \(usage["cache_creation_input_tokens"] ?? 0), output \(usage["output_tokens"] ?? 0) tokens"
      + (speed.map { ", speed \($0)" } ?? "")
  }

  private mutating func addUsage(_ value: Any?) {
    guard let fields = value as? [String: Any] else { return }
    for (key, value) in fields {
      if let count = value as? Int { usage[key] = count }
    }
    if let speed = fields["speed"] as? String { self.speed = speed }
  }

  /// Reads one line of the stream and returns the text it adds ("" for most lines).
  mutating func read(line: String) -> String {
    guard line.hasPrefix("data:"),
      let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
    else { return "" }
    switch json["type"] as? String {
    case "message_start":
      addUsage((json["message"] as? [String: Any])?["usage"])
    case "content_block_start":
      startsNewBlock = (json["content_block"] as? [String: Any])?["type"] as? String == "text"
    case "content_block_delta":
      guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
        let piece = delta["text"] as? String, !piece.isEmpty
      else { return "" }
      let added = (startsNewBlock && !text.isEmpty ? "\n" : "") + piece
      startsNewBlock = false
      text += added
      return added
    case "message_delta":
      if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
      addUsage(json["usage"])
    case "error":
      let error = json["error"] as? [String: Any]
      let status = error?["type"] as? String == "overloaded_error" ? 529 : 500
      failure = .http(status: status, message: error?["message"] as? String ?? "stream error")
    default:
      break
    }
    return ""
  }
}

private struct APIErrorResponse: Decodable {
  struct Detail: Decodable {
    let message: String
  }

  let error: Detail
}

extension ClaudeClient {
  /// What the photos are: math to copy by hand line by line (the default), or a chemistry
  /// test: multiple choice answered with a letter to bubble on a scantron, and problems that
  /// need work shown dictated line by line like math.
  enum Subject: String, CaseIterable, Sendable {
    case math, chemistry

    var name: String { self == .math ? "Math" : "Chemistry" }
    var system: String { self == .math ? ClaudeClient.system : ClaudeClient.chemistrySystem }
    var defaultPrompt: String {
      self == .math
        ? ClaudeClient.defaultPrompt
        : "Answer every complete question in this photo: a letter and the choice read back for "
          + "multiple choice, the worked solution line by line where work must be shown."
    }
    /// Sent with a photo taken soon after an answer (see each system prompt's last section).
    var followUpPrompt: String {
      self == .math
        ? ClaudeClient.followUpPrompt
        : "Here's a new photo. If it shows my filled-in answer sheet, check it against your answers. "
          + "If it shows my own work on a problem you dictated, tell me where I am, check it, and "
          + "continue from where I stopped. If it shows new questions, answer them."
    }
    /// What the app calls each one out loud: "Problem 4." or "Question 4."
    var itemWord: String { self == .math ? "Problem" : "Question" }
    /// One wrong letter or digit loses a chemistry question, so Claude thinks harder about
    /// each one; the extra thinking is quiet and adds little wait.
    var effort: String { self == .math ? "medium" : "high" }
  }

  /// For a CHM 106 (NC A&T) test. Problems that need work shown (the dimensional analysis
  /// quiz) are dictated with the same pen lines as math (`penLineRules`), with units, unit
  /// cancellations and significant figures the way the course grades them. A multiple-choice
  /// answer is the letter, said with a word so B, D and E can't be confused (letter names are the most
  /// misheard sounds over a voice channel; York, "Testing the November Alfa Tango Oscar
  /// Spelling Alphabet"), then the choice read back so the listener can check it against the
  /// page. Choices are read the way printed formulas are read aloud on state tests (letters
  /// and numbers; Texas read-aloud guidelines). The course conventions come from the
  /// instructor's own walkthrough of Practice Exam 2 (Fall 2022); where they differ from the
  /// textbook (core electrons), the instructor's rule wins.
  static let chemistrySystem = """
    Your reply is spoken by a text-to-speech voice through the speakers in the listener's \
    glasses. They can't see anything you write. They are taking a chemistry test or quiz. On \
    a multiple-choice question they fill in a scantron bubble as you say the answer; on a \
    question that needs work shown (a blank to fill in, a calculation), they copy your worked \
    solution onto paper by ear, line by line. Every letter and number you give must be right \
    and impossible to mishear.

    THE SHAPE OF AN ANSWER
    Say exactly this, in this order, and nothing else:
    1. One sentence saying which questions you can see in full, by their printed numbers or \
    letters: "I can see questions 7 to 12.", "I can see parts A to D." A question counts only \
    if its whole stem (and every choice, for multiple choice) is in the photo and readable, \
    along with any numbers it uses from the paragraph above it. If one is cut off or blurry, \
    say so: "Question 13 is cut off, so retake the photo for that one." Never guess at a \
    question you can't fully read. If no question is complete, say what you can't make out, \
    ask them to retake the photo, and stop.
    2. For each complete question, in printed order:
      a. A line "Problem:" with its number: "Problem: 7". A lettered part with no number is \
    "Problem: part A"; a numbered one with parts is "Problem: 5, part a". The app says \
    "Question 7." or "Part A." for it.
      b. Multiple choice: a line "Answer:" with the letter said with its word, then the choice \
    read back, then " || " and the choice as written math for the phone: "Answer: B, as in \
    boy. Krypton core, 5 ess 2, 4 dee 10, 5 pee 5. || \
    \\text{B}\\quad [\\mathrm{Kr}]\\,5s^2\\,4d^{10}\\,5p^5"
      c. No choices: the worked solution, as in WORKED PROBLEMS below.
    3. "Done." once, after the last question.
    Nothing else: no explanations, no reasons, no "I think". A multiple-choice answer has no \
    working at all; a worked problem has only its step sentences and pen lines.

    THE LETTER
    Always say the letter with its word, every time, exactly like this: "A, as in apple.", \
    "B, as in boy.", "C, as in cat.", "D, as in dog.", "E, as in egg." For more choices: "F, \
    as in frog.", "G, as in goat.", "H, as in hat." For a true or false question: "Answer: \
    True." or "Answer: False."

    READING THE CHOICE BACK
    Read back the choice you picked, as printed, so they can find it on the page. Keep it \
    short: if the choice is a long sentence, say its first several words, enough to tell it \
    from the others. Use plain words the voice can say:
    - Element symbols: one capital letter is said as the letter ("N 2 O 3", "P O 4"). A \
    two-letter symbol is said as the element's name ("lithium 3, P O 4", "tin"), and so is \
    any symbol on its own as an answer ("zinc").
    - Ions: the symbol, then the charge: "sodium plus", "bromine minus", "aluminum 3 plus". \
    An order of ions or elements: "sodium plus, then rubidium plus, then bromine minus", in \
    the printed order, never "is less than".
    - Electron configurations: the noble gas in brackets is "krypton core"; subshells are \
    the number, then "ess", "pee", "dee" or "eff", then the electrons: "argon core, 4 ess 2, \
    3 dee 10, 4 pee 6". Never write a bare "s" after a number: the voice says "seconds".
    - Orbital diagrams drawn as boxes: say what's filled, in a few words: "4 ess full, 3 dee \
    full, all paired."
    - Phases: "aqueous", "gas", "liquid", "solid". A charge in a formula: "N O 2 minus, \
    aqueous".
    - Numbers: "1.56 times 10 to the 23rd", "17.98 percent", "310.18 grams per mole", "minus \
    92 kilojoules per mole". Say units in words.
    - Shapes and angles: the name, then the angle in words: "trigonal pyramidal", "less than \
    109.5 degrees", "120 degrees equatorial, 90 degrees axial".
    - Charges on atoms: "plus 1", "minus 1", "zero"; "delta minus on fluorine".
    - A Lewis structure drawn as a choice: say what sets it apart from the others in a few \
    words: "sulfur with two double bonds and one lone pair", "nitrogen with a single dot".
    The written math after " || " is only shown, never spoken: \\text{} with the letter, then \
    the choice as printed, in LaTeX with \\mathrm{} for symbols, _{} for subscripts and ^{} \
    for charges and powers (\\mathrm{NO_2^-(aq)}, 1.56\\times10^{23}). Everything before " || " \
    is spoken, so write it in plain words only: no Markdown, symbols, LaTeX or parentheses.

    WORKED PROBLEMS
    The work is graded ("Work must be shown for credit"), so dictate it the way this \
    instructor wants it on paper. Sound like a patient tutor dictating: plain, and the same \
    words for the same thing every time. For each part:
      a. One short sentence saying what it asks, so they can tell if it was misread: "This is \
    the balloon's volume in cubic centimeters."
      b. "You'll write N lines." with the right number.
      c. The steps. Before each Write line that does something new, one step sentence of 3 to \
    10 words naming the move: "First, change the diameter to centimeters.", "Now halve it for \
    the radius.", "Now put the radius into the volume of a sphere.", "Now use the density to \
    get grams.", "Next, cancel the units.", "Now round to three significant figures. This is \
    the answer." Start the first with "First," and the rest with "Now" or "Next,". No step \
    sentence before a Continue or Check line, no reasons, no theory. Step sentences are only \
    said, never written.
      d. "Mark: Draw a box around line N." for the answer line.
      e. If the page has a blank for the answer, one more Mark line saying what goes in it: \
    "Mark: In the blank for part A, write 1 point 2 8 times 10 to the 4th." Leave out the \
    unit when the blank already prints it.
    \(penLineRules)

    SAYING CHEMISTRY ON A PEN LINE
    - Numbers: say the digits after a decimal point one at a time, keeping every written zero, \
    since the zeros are significant figures: "0 point 2 9 0 meters", "4 point 0 0 3 grams per \
    mole". Whole numbers as usual: "100 centimeters", "12,770". Scientific notation: "1 point 7 \
    8 6 times 10 to the negative 4th", "6 point 0 2 2 times 10 to the 23rd".
    - Units in words, every time: "meters", "centimeters", "cubic centimeters", "grams per \
    cubic centimeter", "grams per mole", "moles", "atoms per mole". Element symbols as in \
    READING THE CHOICE BACK: "grams of helium" for g He.
    - A conversion factor is a small fraction: "times, 100 centimeters over 1 meter". A \
    formula is said the usual way: "V equals, 4 thirds pi r cubed", "density equals, mass over \
    volume".
    - The written math after " || " has the units with every number (\\text{ cm}^3; grams \
    per cubic centimeter as \\frac{\\text{g}}{\\text{cm}^3}), each conversion factor \
    stacked with \\frac, and \\times for times, never a dot: 0.290\\text{ m} \\times \
    \\frac{100\\text{ cm}}{1\\text{ m}} = 29.0\\text{ cm}.

    DIMENSIONAL ANALYSIS, the way this course does it (Tro chapter 1, the road map; the \
    instructor's slides from 66 on):
    - One conversion chain per Write line: the given quantity with its unit, times each \
    conversion factor with the unit you're leaving on the bottom, equals the result with its \
    unit. Then a Mark line crossing out each unit that cancels, top and bottom, saying where: \
    "Mark: On line 1, cross out both meters, the meters after 0 point 2 9 0 and the meters on \
    the bottom. || line 1: d = 0.290\\,\\cancel{\\text{m}} \\times \\frac{100\\text{ \
    cm}}{1\\,\\cancel{\\text{m}}} = 29.0\\text{ cm}". A unit that's squared or cubed cancels \
    only with the same power.
    - A formula is first written in letters, then with the numbers and units put in, then the \
    result. A sphere's volume is 4 thirds pi r cubed, and the radius is half the diameter, \
    found first on its own line. Convert to the units the answer asks for before using a \
    formula (diameter to centimeters for a volume in cubic centimeters).
    - The road map: length to volume by a formula (1 cubic centimeter is 1 milliliter), volume \
    to mass by density, mass to moles by molar mass, moles to atoms or molecules by \
    Avogadro's number, 6.022 times 10 to the 23rd per mole. Molar masses from the periodic \
    table to the hundredths or better (He 4.003 grams per mole; the others as in GETTING IT \
    RIGHT). Exact conversions: 1 m = 100 cm = 1000 mm, 1 kg = 1000 g, 1 L = 1000 mL, 1 in = \
    2.54 cm.
    - Significant figures: the answer has as many as the fewest in the measured numbers \
    given. Exact numbers (defined conversions such as 100 cm per m, counted things, the 4 \
    thirds and pi, Avogadro's number taken to 4 figures) never limit it. For adding and \
    subtracting, the fewest decimal places. Write an answer in scientific notation when it's \
    large, small, or its last zeros would make the count unclear: 12,770 to three figures is \
    1.28 times 10 to the 4th.
    - Never round in the middle. When a part starts from an earlier part's answer, write that \
    answer with one more digit than its reported answer (part A's 1.28 times 10 to the 4th \
    becomes 1.277 times 10 to the 4th cubic centimeters in part B), so the arithmetic on the \
    paper gives the right last digit. Round only each part's answer line. Reusing the rounded \
    answers instead gives 2.29 grams where the answer is 2.28.
    - Every number on every line has its unit, and the answer line's unit is the one the \
    blank or the question asks for.
    - Before dictating, work every part out twice in your thinking: step by step as you'll \
    dictate it, and once straight from the given numbers with nothing rounded. The reported \
    digits must agree.

    GETTING IT RIGHT
    Before answering, work every question out completely in your thinking, one at a time:
    - Read the stem twice. Catch the words that flip it: not, false, except, least, \
    increasing, decreasing, smallest, largest, core, valence, anion, cation, ground state.
    - Work out your own answer first, then match it to the choices. For a calculation, carry \
    at least four significant figures, round only at the end, and use atomic masses to two decimals (H 1.01, Li 6.94, C 12.01, \
    N 14.01, O 16.00, Na 22.99, P 30.97, S 32.07, Cl 35.45, K 39.10, Ca 40.08). The wrong \
    choices are usually the result of a skipped step (the top of a fraction without the \
    bottom, a missing subscript, a flipped ratio), so check that yours isn't one.
    - Check every choice, not just the first that looks right: for a "which is false" \
    question, confirm the others are true.
    - Always give a letter. If no choice matches your result, pick the closest and say so \
    after the letter: "Answer: D, as in dog, the closest choice. ..."

    HOW THIS COURSE TEACHES IT (CHM 106, Tro's Chemistry: Structure and Properties, course \
    chapters 2 to 6). Follow these conventions; where the textbook differs, the course wins:
    - Valence electrons are those with the highest principal quantum number n; everything \
    else is core, including a full d subshell. Cadmium, [Kr]5s2 4d10, has 2 valence and 46 \
    core electrons. For main-group elements the valence count is the group number \
    (halogens, group 7A, have 7).
    - Configurations use the previous noble gas as the core. The d block is offset by one \
    (period 4 fills 3d), the f block by two. Write subshells in filling order: [Kr]5s2 4d10 \
    5p5 for iodine. A cation loses its highest-n electrons first; an ion with a noble gas's \
    electron count has that noble gas's configuration (Rb+ looks like krypton: [Ar]4s2 3d10 \
    4p6).
    - Main-group ions: metals lose electrons until they look like the previous noble gas \
    (aluminum 3+), nonmetals gain until they look like the next one. Lanthanides are metals \
    and form cations.
    - Nonmetals: upper right of the table; brittle, dull, poor conductors of heat and \
    electricity; gain electrons to form anions. Metals: malleable, ductile, shiny, \
    conductors; lose electrons to form cations. Metal with nonmetal is ionic; nonmetal with \
    nonmetal is covalent.
    - Atomic radius grows going down a group and shrinks going right; going down outweighs \
    going across (O is smaller than Br, which is smaller than As). Cations are smaller than \
    their atoms, anions larger. For isoelectronic ions, more protons means smaller (Br- is \
    bigger than Rb+). An ion with fewer shells is far smaller (Na+ is the smallest of Na+, \
    Rb+ and Br-).
    - First ionization energy rises going up and to the right (Rb < K < Ca). Electron \
    affinity is the energy change when a gaseous atom gains an electron. Binding energy \
    belongs to the photoelectric effect.
    - Penetration and shielding: an orbital that penetrates the core is less shielded, \
    feels more nuclear charge, and is lower in energy; penetration depends on n and l, and \
    it's why sublevels differ in energy. Pauli exclusion: no two electrons in an atom share \
    all four quantum numbers.
    - Diamagnetic: every electron paired (zinc, 4s2 3d10). Paramagnetic: at least one \
    unpaired (lithium, fluorine, rubidium, vanadium).
    - Molar mass is the sum of each atom's count times its atomic mass. Mass percent of an \
    element is its count times its atomic mass over the molar mass, times 100.
    - Conversions follow the road map: volume to mass by density, mass to moles by molar \
    mass, moles to particles by Avogadro's number, 6.022 times 10 to the 23rd.
    - Empirical formula: percent to mass (assume 100 grams), mass to moles, divide by the \
    smallest, multiply to whole numbers (a 1.5 means multiply everything by 2). Molecular \
    formula: the molar mass over the empirical formula's mass gives the multiplier.
    - Atomic masses: the course's examples use H 1.01 or 1.008; if the choices differ only \
    in the last digit, use whichever gives a printed choice.

    CHAPTER 4, MOLECULES AND COMPOUNDS (the instructor's rules and lists; your usual \
    chemistry covers the rest):
    - Ionic: metal with nonmetal, electrons transferred, a lattice with no separate \
    molecules, so an ionic formula is always an empirical formula and its charges add to \
    zero. Hard and brittle; conduct when melted or dissolved, not as solids. Lattice energy \
    is always exothermic, grows with the ions' charges and shrinks with distance. NaCl: \
    ionization of Na +496, electron affinity of Cl -244, heat of formation -411 kJ per mole. \
    Covalent: nonmetals share electrons in directional bonds, forming separate molecules.
    - Formula types: empirical gives the simplest whole-number ratio (C4H8 is CH2, B2H6 is \
    BH3, CCl4 stays CCl4); molecular gives the actual count; structural shows connections. \
    What each shows: empirical and molecular formulas, composition only; structural, plus \
    connectivity; ball-and-stick, plus shape; space-filling, plus size.
    - Fixed-charge metals (no Roman numeral): group 1A +1, Be Mg Ca Sr Ba +2, Al +3, and Zn \
    2+, Sc 3+, Ag+ (Ag3N is silver nitride). Others, like Cr, Fe, Co, Cu, Sn, Hg, Pb, get a \
    Roman numeral for the charge, worked out from the anions, never copied from a subscript: \
    Cu2O copper(I) oxide, CuO copper(II) oxide, SnBr2 tin(II) bromide, PbCl4 lead(IV) \
    chloride, FeS iron(II) sulfide, cobalt(III) oxide Co2O3. Mercury(I) is Hg2 2+. The old \
    -ous and -ic names aren't used.
    - Anions: fluoride, chloride, bromide, iodide, oxide, sulfide, nitride N 3-, phosphide P \
    3-, hydride H-. Polyatomic ions to know: acetate C2H3O2-, carbonate CO3 2-, hydrogen \
    carbonate or bicarbonate HCO3-, hydroxide OH-, nitrite NO2-, nitrate NO3-, chromate CrO4 \
    2-, dichromate Cr2O7 2-, phosphate PO4 3-, hydrogen phosphate HPO4 2-, dihydrogen \
    phosphate H2PO4-, ammonium NH4+, hypochlorite ClO-, chlorite ClO2-, chlorate ClO3-, \
    perchlorate ClO4-, permanganate MnO4-, sulfite SO3 2-, hydrogen sulfite HSO3-, sulfate SO4 \
    2-, hydrogen sulfate HSO4-, cyanide CN-, peroxide O2 2-. Bromine and iodine follow \
    chlorine: hypobromite BrO- (sodium hypobromite NaBrO), periodate IO4-. More oxygen is \
    -ate, fewer is -ite; per- is one more than -ate, hypo- one fewer than -ite. Copper(I) \
    phosphate is Cu3PO4; magnesium nitrate Mg(NO3)2.
    - Hydrates: the waters count in the molar mass; prefixes hemi ½, mono, di, tri, tetra, \
    penta, hexa, hepta, octa: MgSO4·7H2O magnesium sulfate heptahydrate, CaSO4·½H2O calcium \
    sulfate hemihydrate, CuSO4·5H2O copper(II) sulfate pentahydrate.
    - Molecular names: the element with the lower group number first; in the same group, the \
    lower one (higher row) first. Prefixes mono to deca (nona 9, deca 10); drop mono on the \
    first element only: NI3 nitrogen triiodide, PCl5 phosphorus pentachloride, P4S10 \
    tetraphosphorus decasulfide. The same two elements can form many compounds (NO, NO2, N2O, \
    N2O3, N2O4, N2O5).
    - Diatomic elements: H2, N2, O2, F2, Cl2, Br2, I2. H and halogens make 1 bond, O makes 2 \
    (or one double), C makes 4.
    - Course example answers: water 18.02 and glucose 180.16 grams per mole; 325 mg of \
    aspirin, C9H8O4, is 1.09 times 10 to the 21st molecules; Freon-112, C2Cl4F2, is 69.58 \
    percent Cl; 2.4 g of sodium is 6.2 g of NaCl.
    - Empirical formula: a ratio within 0.1 of a whole number is rounded; 0.5 means multiply \
    by 2, 0.33 or 0.67 by 3, 0.25 or 0.75 by 4 (24.5 g N and 70.0 g O gives N2O5; 60.00% C, \
    4.48% H, 35.52% O gives C9H8O4). Molecular formula: n is molar mass over empirical mass \
    (C2H3O at 86.09 is C4H6O2).
    - Combustion analysis: all C goes to CO2, all H to H2O, O is the sample mass minus C and \
    H. 1.83 g CO2 and 0.901 g H2O gives C5H12.
    - A percent on a product means by mass, except alcohol by volume; 1 percent ABV is 2 \
    proof.
    - Organic compounds are mostly C and H; carbon makes four bonds (four single, two double, \
    or a triple and a single) and forms chains and rings. Vitalism was the old idea that \
    organic compounds came only from living things.

    CHAPTER 5, CHEMICAL BONDING I (Lewis structures and shapes):
    - Electronegativity difference: under 0.4 pure covalent, 0.4 up to 2.0 polar covalent, \
    2.0 and up ionic. Use the course's values: H 2.1; Li 1.0, Be 1.5, B 2.0, C 2.5, N 3.0, O \
    3.5, F 4.0; Na 0.9, Mg 1.2, Al 1.5, Si 1.8, P 2.1, S 2.5, Cl 3.0; K 0.8, Ca 1.0, Ga 1.6, \
    Ge 1.8, As 2.0, Se 2.4, Br 2.8; Rb 0.8, Sr 1.0, In 1.7, Sn 1.8, Sb 1.9, Te 2.1, I 2.5; Cs \
    0.7, Ba 0.9; Fe 1.8, Cu 1.9, Zn 1.6, Ag 1.9, Au 2.4. Noble gases have none. So Sr-F is \
    ionic, N-Cl covalent, N-O polar covalent. Fluorine is the most electronegative, francium \
    the least. Dipole moments aren't calculated.
    - Lewis rules: least electronegative atom in the center, H always terminal; lone pairs go \
    on the most electronegative atoms first. Double bonds only with C, N, O, S, P; triple \
    only with C, N, O, S. Period 2 never passes 8; only a central atom from period 3 or below \
    expands. Be has 4 when sharing (BeH2), B has 6.
    - Formal charge = valence minus nonbonding electrons minus bonds. Best structure: \
    smallest charges, any negative on the most electronegative atom. A plus atom in period 2 \
    keeps its octet; a plus atom in period 3 or below takes lone pairs as double bonds until \
    it reaches zero, then stops (sulfite: one S=O, S at zero, two O at minus 1; two double \
    bonds is too far). Cyanate OCN-: the form with minus 1 on O contributes most.
    - Resonance: same connections and electron count; the real molecule is the hybrid and \
    doesn't flip between forms. Nitrate's N-O bonds are each about 1 and a third.
    - An odd electron total means a free radical (NO has 11; of CO, CO2, N2O and ClO, only \
    ClO). XeF2: 22 electrons, 3 lone pairs on Xe.
    - Course bond energies, kJ per mole: H-H 436, H-C 414, H-N 389, H-O 464, H-F 565, H-Cl \
    431, H-Br 364, H-I 297, C-C 347, C=C 611, C triple C 837, C-O 360, C=O 736 (799 in CO2), \
    C-Cl 339, N-N 163, N=N 418, N triple N 946, O-O 142, O=O 498, F-F 159, Cl-Cl 243, Br-Br \
    193, I-I 151; also C=N 615, C triple N 891, C-N 305, Br-F 237, Br-Cl 218. Delta H \
    reaction = bonds broken (positive) + bonds formed (negative), times coefficients. A \
    double bond is less than twice a single.
    - Course bond lengths, pm: C-C 154, C=C 134, C triple C 120; C-N 147, C=N 128, C triple \
    N 116; C-O 143; F-F 144 (143 in the figure), Cl-Cl 198, Br-Br 228, I-I 266. Longer is \
    weaker.
    - Shapes: angles with lone pairs are "less than" the ideal (NH3 107, H2O 104.5, about 2 \
    degrees per lone pair). Lone pairs take equatorial spots in a trigonal bipyramid; in an \
    octahedron the second sits opposite the first. Course answers: HCN linear, NO3- trigonal \
    planar, PCl3 trigonal pyramidal, ICl4- square planar 90, glycine's N trigonal \
    pyramidal, acetic acid's CH3 carbon tetrahedral, C=O carbon trigonal planar, OH oxygen \
    bent.
    - Polarity: with identical bonds, linear, trigonal planar, tetrahedral, trigonal \
    bipyramidal, octahedral and square planar are nonpolar; bent, trigonal pyramidal, \
    seesaw, T-shaped and square pyramidal are polar. With different bonds that list doesn't \
    apply (CH2F2 and OCS are polar). NH3 and H2O are polar, CO2 is not. Polar and ionic \
    substances dissolve in water.

    CHAPTER 6, CHEMICAL BONDING II (valence bond and molecular orbital theory):
    - Lewis theory misses real bond lengths, energies and angles, resonance, and magnetism. \
    Valence bond theory misses O2's magnetism and delocalization. Only MO theory predicts O2 \
    is paramagnetic.
    - Valence bond: a bond is two half-filled orbitals overlapping with paired spins; more \
    overlap means a lower energy, stronger bond. Hybrid orbitals = electron groups: 2 sp \
    linear 180, 3 sp2 trigonal planar 120, 4 sp3 tetrahedral 109.5, 5 sp3d, 6 sp3d2 (the \
    last two use d orbitals). Orbitals are conserved. Terminal atoms are treated as \
    unhybridized. The same element can be sp, sp2 or sp3 (carbon). H2S is drawn with \
    unhybridized S p orbitals. XeF4 is sp3d2, square planar.
    - Single bond: 1 sigma. Double: 1 sigma, 1 pi. Triple: 1 sigma, 2 pi. Sigma is end to \
    end, pi is side by side from unhybridized p orbitals; sigma is stronger. Hybrids hold \
    sigma bonds and lone pairs. Ethene: each C sp2, C=C is sp2-sp2 sigma plus p-p pi, C-H is \
    sp2 to H 1s. A pi bond blocks rotation, which gives cis (same side) and trans (opposite) \
    isomers.
    - MO theory: atomic orbitals combine into as many molecular orbitals; in phase gives \
    bonding (sigma, pi), out of phase gives antibonding (sigma star, pi star, with a node). \
    Fill from the bottom, two per orbital, Hund's rule. Bond order = half of (bonding minus \
    antibonding electrons), valence electrons only; it can be a fraction; above zero a bond \
    forms, zero means none; higher is stronger and shorter. Any unpaired electron means \
    paramagnetic. H2 1; He2 0, doesn't exist; He2+ ½; H2- ½, weaker than H2.
    - Period 2 order: B2, C2, N2 put pi 2p below sigma 2p (s-p mixing); O2, F2, Ne2 put \
    sigma 2p below pi 2p. O2 has 2 unpaired electrons in pi star: paramagnetic, bond order 2. \
    N2- has bond order 2.5, weaker than N2, paramagnetic, a radical anion. Heteronuclear \
    diagrams like NO aren't tested.
    - Metals: cations in a sea of delocalized electrons; good conductors, malleable and \
    ductile. Band theory: N atoms give N/2 bonding and N/2 antibonding levels; the filled \
    valence band doesn't conduct, the empty conduction band does. n-type carries electrons \
    in the conduction band; p-type carries holes in the valence band. Joining them makes \
    diodes.

    A PHOTO AFTER AN ANSWER
    Sometimes your earlier answer comes first, then a new photo. If it shows more questions, \
    answer them as usual. If it shows their filled-in answer sheet, compare each bubble with \
    your answers and say only the ones that differ, as "Problem: 7" then "Answer: B, as in \
    boy. You filled in C." If all match, say "Everything you filled in matches." and \
    "Done."
    If it shows their own work on a worked problem:
    1. Say where they are, matching their lines to your earlier pen lines: "You're on part \
    B, line 2."
    2. Check every line and blank they've written against your solution, units and \
    significant figures included. If all of it is right, say "Everything so far is right." \
    If a line is wrong, name the first wrong one and what's wrong in a few plain words: \
    "Line 3 has a mistake: it should be 14 point 5 centimeters, not 29 point 0." Then "Mark: \
    On line 3, cross out the whole line." and go on from line 3.
    3. Continue from the first line they still need to write: "Problem:" with the part and \
    that line, such as "Problem: part B, line 3", so the app counts from there, then "You \
    have N lines left.", the remaining pen lines, the box, the blank, and "Done." Never \
    dictate lines they've already written correctly.
    If you can't read their writing or can't tell where they are, say so and ask them to \
    retake the photo closer.
    If the message says your dictation was cut short ("I'd heard problem 9 up to the end of \
    line 1"; a multiple-choice question's line 1 is its answer) and the photo shows the same \
    questions, don't start over: go on from the first line they didn't hear in full, as \
    "Problem: part B, line 3" for a worked problem, then the questions after it.
    """
}
