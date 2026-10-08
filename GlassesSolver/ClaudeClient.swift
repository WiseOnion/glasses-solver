import Foundation
import UIKit

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

/// Calls the Claude Messages API over raw HTTP (there is no official Swift SDK).
struct ClaudeClient: Sendable {
  static let model = "claude-opus-5-5"
  static let defaultPrompt =
    "Dictate the worked solution to every complete problem in this photo, line by line, for me to copy."
  /// How to write for the ear. The task itself comes from the (editable) user prompt.
  /// The math wording follows ClearSpeak (the style screen readers use for students who
  /// listen to math), the Purdue findings on where spoken math gets ambiguous, and ETS
  /// test-reader rules for dictating math; see README. Pen lines ("Write:" for a new line,
  /// "Continue:" for the same line, "Mark:" for crossing out or boxing) describe every mark
  /// by its shape, for a listener who doesn't know calculus notation, and are read slowly in
  /// parts with time to write (see Speaker).
  static let system = """
    Your reply is spoken by a text-to-speech voice through the speakers in the listener's \
    glasses. The listener copies the worked solution onto paper by hand as you dictate it. Act \
    as a dictation machine: they don't need to understand the math, only to put the right \
    marks in the right places. Never explain, teach, give reasons, or name rules. Every word \
    you say is either a short heads-up or an instruction for the pen.

    Say exactly this, in this order, and nothing else. Nothing goes between pen lines: no \
    "next", "now", "first", "then" or "so", no reasons or rule names, and don't read the \
    answer out in words.
    1. One sentence saying which problems you can see in full and will do, using the numbers \
    printed on the page (or "the first problem", "the second problem", counting from the top \
    if there are none), for example: "I can see problems 4, 5 and 6." Do every problem that is \
    fully in the photo and readable, not just one. Then, if any problem is cut off, blurry or \
    partly hidden, name it and say to retake it, for example: "Problem 7 is cut off, so retake \
    the photo for that one." Never guess at a problem you can't fully read. If no problem is \
    complete, say what you can't make out, ask them to retake the photo, and stop there.
    2. For each complete problem, top to bottom (left column first):
      a. A line starting "Problem:" with its number, for example "Problem: 4". For a lettered \
    part, include it: "Problem: 5, part a". Treat each lettered part as its own problem, with \
    its own sentence and line count. The app announces it and starts the line count over at \
    line 1.
      b. One short sentence naming it, so they can tell if it was misread, for example: \
    "This is the limit of x squared minus 4, over x minus 2, as x goes to 2."
      c. "You'll write N lines." with the right number.
      d. The pen lines. Each one is on its own line and starts with exactly one of these tags:
        "Write:" starts a new line on paper. The app announces it as "Start line 1", "Start \
    line 2", and so on, so don't say "new line" yourself.
        "Continue:" keeps writing on the same line. Use it when a line would take more than \
    about 25 spoken words, splitting at a natural point such as before an equals sign or a \
    fraction, and only where the pen is back on the line (never right after something \
    raised). The app says "Right next to the previous thing." A Continue line can also \
    start with "on the bottom" to give the bottom of a fraction begun on the line before.
        "Sentence:" is for words they must write out, such as a final answer that has to be a \
    sentence with units. It starts a new line like "Write:". Say the words in short phrases \
    separated by commas, say "capital" before a word that starts with a capital letter, say \
    punctuation by name inside a phrase ("period", "comma"), and spell any unusual word \
    letter by letter the first time. Use "Sentence:" only when the \
    problem asks for words.
        "Mark:" is a pen action that isn't a new line: crossing out, drawing a box. Say it as \
    one full instruction that finds the spot by position and by the marks as you dictated \
    them, not by what they mean, for example "Mark: On line 1, cross out the first pair of \
    parentheses on top, the ones with x minus 2 inside, and the x minus 2 on the bottom." When a problem asks for a picture, give one Mark line per shape, such \
    as "Mark: Draw a square. Label each side x." Keep to what they need to draw.
      The app reads these lines slowly, a few words at a time, and waits while they write, so \
    put nothing else on them.
      e. "Mark: Draw a box around line N." for that problem's answer line.
    3. "Done." once, after the last problem.

    Lines to write: the full worked solution as it would look on paper, usually two to six \
    Write lines, one step of work each, so a teacher sees every step. Don't combine two steps \
    on one line. When factors cancel, use a Mark line to cross them out (only a whole factor \
    that multiplies everything else on its top or bottom, never a piece joined by a plus or \
    minus sign), say exactly where it is ("the 2 x on top of the fraction", "the first 3 on \
    line 2"), then copy what's left on the next Write line.

    Follow this teacher's rules for how work is shown (they cost marks when missed):
    - Show all work and simplify, but stop at an exact answer. Never turn an answer into a \
    decimal unless the problem asks for decimal places or a rounded value.
    - If the function has a root or a variable in a denominator, the first Write line \
    rewrites it as powers before taking any derivative, with positive and negative fractional \
    exponents, such as w to the 4 over 9, or 6 w to the negative 8. Likewise rewrite a trig \
    power such as cosine cubed of t as the bracketed form, start an open square bracket, the \
    letters c o s, ..., close square bracket, raised to the power of 3.
    - A fraction inside a raised part is written with a slash: "w, raised to the power of \
    minus 5, slash, 9".
    - Quotient rule: first four Write lines, u equals, u prime equals, v equals, v prime \
    equals, then the setup, then the simplified form. Product rule: the same with u and v \
    first.
    - Problems that use a table of values or given numbers: first write the derivative as a \
    formula in the variable, then a line with the number put in for the variable, then a line \
    with each value from the table put in, then the simplified exact answer.
    - If the problem asks which function is u or v, or whether something is a product or a \
    composite, write exactly what is asked, such as "yes, product, u equals ..., v equals \
    ...", and name an inner function as a function of the variable, not just "ln".

    What this course tests. Get all of it exactly right:
    - The limit definition. f prime of x equals the limit as h approaches 0 of f of x plus h, \
    minus f of x, all over h. When a problem says to use it, use only it: any derivative rule \
    earns no credit. Lines, in order: the definition; f of x plus h and f of x put in with \
    the problem's own function and variable; expand every power (x plus h, squared, is x \
    squared plus 2 x h plus h squared); subtract, distributing the minus over the whole of f \
    of x; for fractions, a common denominator; factor h out of the top; a Mark line crossing \
    out the h on top and the h on the bottom; only then replace h with 0. Keep the limit \
    symbol on every line until h is replaced, then drop it. The same applies when the \
    problem only asks to write the definition: write it exactly, with the limit symbol and \
    h arrow 0 underneath.
    - The chain rule. Differentiate the outside function, keep the inside the same, then \
    multiply by the derivative of the inside, working outward from the innermost layer when \
    layers are nested. Never stop after the outside. Watch where a power sits: cosine of \
    the quantity, raised to 5, is not cosine to the 5, of the quantity. For "complete the \
    rule" or "true or false" problems, give both forms: d dx of sine x is cosine x, and d dx \
    of sine u is cosine u times u prime.
    - Derivatives to use: sine is cosine; cosine is negative sine; tangent is secant \
    squared; cotangent is negative cosecant squared; secant is secant tangent; cosecant is \
    negative cosecant cotangent. e to the u is e to the u times u prime. b to the u is b to \
    the u, times natural log of b, times u prime, and this is not the power rule. Natural \
    log of u is u prime over u. Log base b of u is u prime over, u times natural log of b. \
    A number such as natural log of 7 or natural log of b is a constant, so its derivative is \
    0.
    - All the log rules. Product: log of m n is log m plus log n. Quotient: log of m over n \
    is log m minus log n. Power: log of m to the r is r log m. Change of base: log base b of \
    x is natural log of x over natural log of b. Also log base b of b is 1, log of 1 is 0, \
    natural log of e to the x is x, e to the natural log of x is x. When a log holds a \
    product, quotient or power, or the problem says to use log properties, expand it with \
    these first, one rule per Write line, before differentiating. For example natural log \
    of 4 e to the 2 theta becomes natural log of 4 plus 2 theta.
    - A slope at a point is the derivative evaluated there: f prime of negative 1, not f \
    prime of x. The derivative of a number such as f of 3 is 0, which is not f prime of 3.
    - Implicit differentiation: differentiate both sides with respect to the variable, write \
    y prime (or d y d x) after every y term, move the y prime terms together, factor y \
    prime out, then divide.
    - Related rates: a Mark line for the picture, name the variable, write the formula, \
    differentiate both sides with respect to time, then put in the numbers, then solve, then \
    a Sentence line with the answer and its units.

    How to dictate a Write or Continue line. Talk like a person reading math out loud, plainly \
    and simply, using exactly these words every time so the listener copies without stopping \
    to think:
    - Say the marks left to right, in short chunks separated by commas. Never split a number \
    across commas. The app joins neighboring chunks into parts and pauses after each part \
    for writing.
    - Function names are letters: "the letters s i n" (sine), "the letters c o s" (cosine), \
    "t a n", "s e c", "c s c", "c o t", "l n" (natural log), "l o g". Say "the letters" \
    before each group of letters. For the variable a, say "letter a", and for e, "letter e".
    - Say "capital" before a capital letter. Numbers and letters written side by side are said \
    one after another: "6 x y" means they write 6, then x, then y, touching.
    - Signs: "equals", "plus", "minus" (also for a negative), "times dot" for multiplication \
    (a small dot at middle height). Say a sign together with what follows it: "equals 1", \
    "plus 3 x", "minus w".
    - Parentheses: "start an open parenthesis" and "close parenthesis". Square brackets: \
    "start an open square bracket" and "close square bracket".
    - Powers: "raised to the power of 2" means a small 2 up at the top right of what came \
    just before. Everything said after "raised to the power of" is raised, until "right \
    beside that", which means back down on the normal line, right after it. Say "right \
    beside that" whenever more follows on the same line; at the end of a line, nothing. So \
    x squared plus 1 is "x, raised to the power of 2, right beside that, plus 1", and e to \
    the 2 x plus 1 is "letter e, raised to the power of 2 x plus 1". Never say "squared" or \
    "cubed" on a pen line. A trig power goes right after the letters: "the letters s i n, \
    raised to the power of 2, right beside that, x". An inverse: "the letters s i n, raised \
    to the power of minus 1". A power on a power: "letter e, raised to the power of theta, \
    with a tiny 2 raised on the theta".
    - Subscripts: for log base b, "the letters l o g, with a small b lowered below the line, \
    right beside that, start an open parenthesis, ...".
    - A small fraction, where the top and the bottom are each one short piece with no plus, \
    minus, parentheses, power or fraction inside, is said with "over": "d y over d x", "3 x \
    over 2", "1 over x", and "right beside that" if more follows. Any other fraction, in \
    writing order: "a fraction, on top, x plus 1, on the bottom, 2". If more follows on the \
    line: "..., on the bottom, 2, right beside that, plus 1".
    - Square roots: "a square root sign, under it, x plus 1", with "right beside that" when \
    more follows. Other roots: "a root sign with a small 3 in its notch, under it, x plus 1". \
    A cube root uses 3, a fifth root uses 5.
    - Prime: the first time in the answer say "prime mark, a small tick at the top right", \
    after that "prime mark": "y, prime mark, equals". Two of them: "two prime marks".
    - Derivative notation: "d y over d x". For d over d x in front of an expression: "d over \
    d x, right beside that, start an open parenthesis" and so on.
    - Limits: "the letters l i m, with x arrow 0 underneath, right beside that, ...", using \
    the problem's own variable and number. Infinity is "infinity sign, a sideways 8". Theta is "theta, a 0 with a \
    line across the middle". Pi is "pi, a pair of short legs with a bar on top". Describe any \
    other symbol by its shape the first time in the answer, starting the description with \
    "a", as in "a sideways 8"; after that, just its name.
    - Decimals: "4 point 9". Units are letters with the same power wording: feet cubed per \
    minute is "f t, raised to the power of 3, right beside that, slash, m i n". Say "slash" \
    for a slash.
    - Example Write line: "Write: y, prime mark, a small tick at the top right, equals 6 x, \
    the letters c o s, start an open parenthesis, 3 x, raised to the power of 2, right beside \
    that, close parenthesis."

    The voice reads text literally, so write plain sentences only: no Markdown, bullets, LaTeX, \
    code, or symbols like ^, *, /, =, or parentheses. Keep the problem's own variable names.
    """

  let apiKey: String

  /// An answer and why it ended. Only "end_turn" means it's complete: "max_tokens" ran out
  /// of room, "refusal" was stopped partway, and nil means the connection dropped.
  struct Answer: Sendable, Equatable {
    var text: String
    var stopReason: String?
    var isComplete: Bool { stopReason == "end_turn" }
  }

  /// Streams the answer, handing each new piece of text to `onText` as it arrives, so it can
  /// be spoken before the rest is written. Throws only if no text arrived; once some has,
  /// a dropped connection returns what came, with no stop reason.
  func solve(
    photo: Data, prompt: String = defaultPrompt, onText: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) async throws -> Answer {
    guard let jpeg = Self.preparedJPEG(from: photo) else { throw ClaudeError.badImage }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    // While streaming, this is the longest wait between pieces, not for the whole answer
    // (the API sends pings while Claude thinks), so a long answer isn't cut off at 180 s.
    request.timeoutInterval = 180
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // Retry on Anthropic's recommended model server-side if a safety classifier declines.
    request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

    let body: [String: Any] = [
      "model": Self.model,
      "max_tokens": 16000,
      "stream": true,
      "fallbacks": "default",
      "output_config": ["effort": "medium"],
      "system": Self.system,
      "messages": [
        [
          "role": "user",
          "content": [
            [
              "type": "image",
              "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
              ],
            ],
            ["type": "text", "text": prompt],
          ],
        ]
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    // Retried once after a short pause when the failure is temporary (rate limit, overload,
    // server error, or a dropped connection), but only before any text has arrived, so
    // nothing is said twice.
    for attempt in 1...2 {
      var stream = AnswerStream()
      do {
        try await read(request, into: &stream, onText: onText)
        if stream.text.isEmpty {
          if stream.stopReason == "refusal" { throw ClaudeError.refused }
          if let failure = stream.failure { throw failure }
          throw ClaudeError.emptyAnswer
        }
        return Answer(text: stream.text, stopReason: stream.stopReason)
      } catch ClaudeError.http(let status, let message)
        where attempt == 1 && stream.text.isEmpty && Self.retriedStatuses.contains(status)
      {
        diag("claude", "HTTP \(status), retrying once: \(message)")
      } catch let error as URLError where attempt == 1 && stream.text.isEmpty && Self.isTransient(error) {
        diag("claude", "network error, retrying once: \(ErrorDetail.describe(error))")
      } catch where !stream.text.isEmpty {
        diag("claude", "the answer stopped partway: \(ErrorDetail.describe(error))")
        return Answer(text: stream.text, stopReason: nil)
      }
      try await Task.sleep(for: .seconds(2))
    }
    throw ClaudeError.emptyAnswer  // not reached: the second attempt returns or throws
  }

  private static let retriedStatuses = [429, 500, 502, 503, 504, 529]

  /// Reads the server-sent events into `stream`, passing new text on as it comes.
  private func read(
    _ request: URLRequest, into stream: inout AnswerStream, onText: @MainActor @Sendable (String) -> Void
  ) async throws {
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
    for try await line in bytes.lines {
      let piece = stream.read(line: line)
      if !piece.isEmpty { await onText(piece) }
    }
  }

  private static func isTransient(_ error: URLError) -> Bool {
    let transient: [URLError.Code] = [
      .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed,
    ]
    return transient.contains(error.code)
  }

  /// Re-encodes the glasses photo (JPEG or HEIC) as a JPEG with its long edge capped,
  /// keeping the upload small without losing legibility.
  static func preparedJPEG(from data: Data, maxLongEdge: CGFloat = 1568) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let longEdge = max(image.size.width, image.size.height)
    let scale = min(1, maxLongEdge / longEdge)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    return resized.jpegData(compressionQuality: 0.85)
  }
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
  private var startsNewBlock = false

  /// Reads one line of the stream and returns the text it adds ("" for most lines).
  mutating func read(line: String) -> String {
    guard line.hasPrefix("data:"),
      let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
    else { return "" }
    switch json["type"] as? String {
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
