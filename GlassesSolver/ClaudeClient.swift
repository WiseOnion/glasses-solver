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
    Never change the math to make it look nicer. Keep each written line narrow enough for a \
    phone, about 25 symbols: break a longer one with \\\\ before a top-level =, + or -, and the \
    rest shows on the next row. \\cancel only a factor common to the whole top and bottom, never \
    a term of a sum, and \\underline{...} an intermediate result the problem asks for.
    Inside a Write or Continue line, commas are the short breaths a person reading math aloud \
    takes: right after every "equals", before each plus or minus that starts a new term, and \
    around anything in parentheses, such as "u equals, 1, plus tangent w" or "g prime of w \
    equals, a fraction". Keep a term together ("negative 3 w squared", "secant squared w"), and \
    never split a number. The app stops for writing only after whole pieces of math (after \
    "equals", or before a new term outside parentheses), never inside a term or a group, and \
    decides how long from how much there is to write.

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

  let apiKey: String
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
    let messages = Self.messages(jpeg: jpeg, prompt: prompt, previousAnswer: previousAnswer, stoppedAt: stoppedAt)
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
        let part = try await stream(try Self.request(apiKey: apiKey, messages: messages, fast: true), continuing: continuing, onText: onText)
        diag("claude", "fast mode, \(part.usageDescription)")
        return part
      } catch ClaudeError.http(let status, let message) where [400, 403, 404, 429].contains(status) {
        diag("claude", "fast mode wasn't accepted (HTTP \(status): \(message)); using standard speed")
        let aboutSpeed = message.lowercased().contains("speed") || message.lowercased().contains("fast")
        if status == 403 || status == 404 || (status == 400 && aboutSpeed) { Self.fastModeRefused.set(true) }
        fast = false
      }
    }
    let part = try await stream(try Self.request(apiKey: apiKey, messages: messages, fast: false), continuing: continuing, onText: onText)
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
  static func body(jpeg: Data, prompt: String, previousAnswer: String?, stoppedAt: String? = nil) -> [String: Any] {
    body(messages: messages(jpeg: jpeg, prompt: prompt, previousAnswer: previousAnswer, stoppedAt: stoppedAt))
  }

  /// The conversation sent for a photo (see `body(jpeg:prompt:previousAnswer:stoppedAt:)`).
  static func messages(jpeg: Data, prompt: String, previousAnswer: String?, stoppedAt: String?) -> [[String: Any]] {
    let image: [String: Any] = [
      "type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
    ]
    let followUpText: String = [stoppedAt, Self.followUpPrompt].compactMap { $0 }.joined(separator: " ")
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
  static func body(messages: [[String: Any]], fast: Bool = false) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "stream": true,
      "fallbacks": "default",
      "output_config": ["effort": "medium"],
      "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
      "messages": messages,
    ]
    if fast { body["speed"] = "fast" }
    return body
  }

  private static func request(apiKey: String, messages: [[String: Any]], fast: Bool) throws -> URLRequest {
    var request = try request(apiKey: apiKey, fast: fast)
    request.httpBody = try JSONSerialization.data(withJSONObject: body(messages: messages, fast: fast))
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
