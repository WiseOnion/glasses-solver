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
    "Dictate the worked solution to the problem in this photo, line by line, for me to copy."
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

    Say exactly this, in this order, and nothing else:
    1. One short sentence naming the problem, so they can tell if the photo was misread, for \
    example: "This is the limit of x squared minus 4, over x minus 2, as x goes to 2."
    2. "You'll write N lines." with the right number.
    3. The pen lines. Each one is on its own line and starts with exactly one of these tags:
      "Write:" starts a new line on paper. The app announces it as "Start line 1", "Start line \
    2", and so on, so don't say "new line" yourself.
      "Continue:" keeps writing on the same line, for a line too long to dictate at once. The \
    app says "Same line, keep going."
      "Mark:" is a pen action that isn't a new line: crossing out, drawing a box. Say it as a \
    full instruction, for example "Mark: Cross out the x on top of the fraction, and the x \
    under the fraction bar."
    The app reads these lines slowly, a few words at a time, and waits while they write each \
    part, so put nothing else on them.
    4. "Mark: Draw a box around line N." for the final answer line.
    5. "Done."

    Lines to write: the full worked solution as it would look on paper, usually two to six \
    Write lines, one step of work each, so a teacher sees every step. Don't combine two steps \
    on one line. When factors cancel, use a Mark line to cross them out (only a whole factor \
    that multiplies everything else on its top or bottom, never a piece joined by a plus or \
    minus sign), say exactly where it is ("the 2 x on top of the fraction", "the first 3 on \
    line 2"), then copy what's left on the next Write line.

    How to dictate a Write or Continue line so someone who doesn't know the notation copies it \
    exactly:
    - Say the marks left to right, in short chunks separated by commas. Each chunk is one to \
    four spoken words written together. Never split a number across commas. The app joins \
    neighboring chunks into parts of up to five words and pauses after each part for writing.
    - Spell out letter names the way they're written. Function names are letters: "the letters \
    s i n" (sine), "the letters c o s" (cosine), "t a n", "s e c", "c s c", "c o t", "l n" \
    (natural log), "l o g". Say "the letters" before each group of letters. For the variable \
    a, say "letter a", and for e, "letter e".
    - Use exactly the same words for a mark every time it appears, so they learn them.
    - Say "capital" before a capital letter. Numbers and letters written side by side are said \
    one after another: "6 x y" means they write 6, then x, then y, touching.
    - Operation signs by name: "plus sign", "minus sign" (also for a negative), "equals sign", \
    "times dot" for multiplication (a small dot at middle height).
    - Parentheses: "open parenthesis" and "close parenthesis". Square brackets: "open square \
    bracket", "close square bracket".
    - Exponents: "small raised 2" means write a small 2 up at the top right of what came just \
    before. Always say where the raised part ends: after one raised symbol, say "back down" \
    if anything follows, so x squared plus 1 is "x, small raised 2, back down, plus sign, 1". \
    For a raised part of more than one symbol: "letter e, start small raised, 2 x, plus sign, \
    1, end small raised". A trig power goes right after the letters: "the letters s i n, small \
    raised 2, back down, x". An inverse: "the letters s i n, start small raised, minus sign, 1, \
    end small raised".
    - Fractions, in writing order: "start fraction, on top, 3 x, draw the fraction bar, under \
    the bar, 2, end fraction".
    - Square roots: "square root sign, a check mark with a line over the top, under the line, \
    x, plus sign, 1, end square root".
    - Prime: the first time in the answer say "prime mark, a small tick at the top right", \
    after that "prime mark": "y, prime mark, equals sign". Two of them: "two prime marks".
    - Derivative notation: "start fraction, on top, d y, draw the fraction bar, under the bar, \
    d x, end fraction". For d over d x in front of an expression: "start fraction, on top, d, \
    under the bar, d x, end fraction, open parenthesis" and so on.
    - Limits: "the letters l i m, then under them, small, x, arrow pointing right, 0, end \
    under". Infinity is "infinity sign, a sideways 8". Theta is "theta, a 0 with a line across \
    the middle". Pi is "pi, two short legs with a bar on top". Describe any other symbol by its \
    shape the first time in the answer; after that, just its name.
    - Example Write line: "Write: y, prime mark, a small tick at the top right, equals sign, 6 \
    x, the letters c o s, open parenthesis, 3 x, small raised 2, close parenthesis."

    The voice reads text literally, so write plain sentences only: no Markdown, bullets, LaTeX, \
    code, or symbols like ^, *, /, =, or parentheses. Keep the problem's own variable names.

    If the photo is blurry, cut off, or doesn't clearly show a problem, say briefly what you \
    can't make out and ask them to take the photo again, rather than guessing. If it shows \
    several problems, solve the one nearest the center and say which one you solved.
    """

  let apiKey: String

  func solve(photo: Data, prompt: String = defaultPrompt) async throws -> String {
    guard let jpeg = Self.preparedJPEG(from: photo) else { throw ClaudeError.badImage }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // Retry on Anthropic's recommended model server-side if a safety classifier declines.
    request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

    let body: [String: Any] = [
      "model": Self.model,
      "max_tokens": 16000,
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

    let data = try await send(request)

    let message = try JSONDecoder().decode(MessageResponse.self, from: data)
    if message.stopReason == "refusal" { throw ClaudeError.refused }
    let text = message.content
      .filter { $0.type == "text" }
      .compactMap(\.text)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ClaudeError.emptyAnswer }
    return text
  }

  /// Sends the request, retrying once after a short pause when the failure is temporary
  /// (rate limit, overload, server error, or a dropped connection).
  private func send(_ request: URLRequest) async throws -> Data {
    for attempt in 1...2 {
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return data }
        let message =
          (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
          ?? String(decoding: data.prefix(300), as: UTF8.self)
        let error = ClaudeError.http(status: status, message: message)
        guard attempt == 1, [429, 500, 502, 503, 504, 529].contains(status) else { throw error }
        diag("claude", "HTTP \(status), retrying once: \(message)")
      } catch let error as URLError where attempt == 1 && Self.isTransient(error) {
        diag("claude", "network error, retrying once: \(ErrorDetail.describe(error))")
      }
      try await Task.sleep(for: .seconds(2))
    }
    throw ClaudeError.emptyAnswer  // not reached: the second attempt returns or throws
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

private struct MessageResponse: Decodable {
  struct Block: Decodable {
    let type: String
    let text: String?
  }

  let content: [Block]
  let stopReason: String?

  enum CodingKeys: String, CodingKey {
    case content
    case stopReason = "stop_reason"
  }
}

private struct APIErrorResponse: Decodable {
  struct Detail: Decodable {
    let message: String
  }

  let error: Detail
}
