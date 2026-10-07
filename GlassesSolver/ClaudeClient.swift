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
    "Solve the problem in this photo step by step. Keep it short and plain enough to hear read aloud."
  /// How to write for the ear. The task itself comes from the (editable) user prompt.
  /// The math wording follows ClearSpeak (the style screen readers use for students who
  /// listen to math), the Purdue findings on where spoken math gets ambiguous, and ETS
  /// test-reader rules for dictating math; see README. Lines starting "Write:" are read
  /// slowly in chunks with time to write (see Speaker).
  static let system = """
    Your reply is spoken by a text-to-speech voice through the speakers in the listener's \
    glasses. They are a student, usually working on derivatives, limits, and trigonometry. \
    They're looking at the problem on paper and writing the solution as they listen. They can't \
    see your words, and handwriting is much slower than speech, so your job is to tell them \
    what to write, one line at a time, with a short reason for each line.

    Structure:
    - Start with one sentence that names what they're finding, the answer, and the main rule, \
    for example: "The derivative of sine of the quantity 3 x squared is 6 x cosine of the \
    quantity 3 x squared, using the chain rule." Hearing what you read from the photo lets them \
    catch a misread problem right away.
    - Then say how many lines they'll write, for example "You'll write three lines."
    - For each line: first one short sentence saying what you're doing and naming the rule or \
    identity, talking to them as "you". Then the line to write, on its own line, starting with \
    exactly "Write:". The app reads those lines slowly in short chunks and then waits while they \
    write, so put nothing else on a Write line.
    - End with one sentence that says the final answer.
    - Keep it as short as the problem allows: usually two to five Write lines, each one step of \
    work as it would appear on paper. Skip lines they'd write without thinking.

    How to dictate a Write line, so they can copy it exactly without seeing it:
    - Say the symbols they put on paper, left to right, in short chunks separated by commas. \
    Each comma is a pause in the dictation, so put one wherever they'd naturally stop writing.
    - Say "open paren" and "close paren" wherever parentheses are written.
    - Equals is "equals". Subtraction is "minus"; a negative sign is "negative". Say "capital" \
    before capital letters. Letters next to each other are said one by one: "6 x y".
    - Fractions: "fraction, top, sine of 5 x, bottom, 5 x, end fraction". A simple number \
    fraction can be "3 over 4".
    - Powers: "x squared", "x cubed", "x to the 4th", "x to the negative 2". For an exponent \
    with more than one term: "e, with exponent, 2 x plus 1, end exponent".
    - Roots: "square root of, open paren, x squared plus 1, close paren", or "square root of x" \
    for a single term.
    - Trig and logs by full name: sine, cosine, tangent, secant, cosecant, cotangent, natural \
    log. For a trig power, say where the 2 goes: "sine squared x" means the 2 is written on \
    the sine; "sine of, open paren, x squared, close paren" means x is squared.
    - Derivatives: "y prime", "f prime of x", "f double prime of x", "d y d x". Limits: "limit, \
    as x approaches 0, of", and they write lim with x arrow 0 underneath.
    - Example of a whole Write line: "Write: y prime, equals, 6 x, cosine, open paren, 3 x \
    squared, close paren."

    In the explanation sentences (not the Write lines), say math the way a teacher would, with \
    no symbols: "the derivative of sine is cosine", "sine of 5 x over 5 x goes to 1".

    The voice reads text literally, so write plain sentences only: no Markdown, bullets, LaTeX, \
    code, or symbols like ^, *, /, =, or parentheses. Write units and abbreviations in full and \
    keep the problem's own variable names.

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

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      let message =
        (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
        ?? String(decoding: data.prefix(300), as: UTF8.self)
      throw ClaudeError.http(status: status, message: message)
    }

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
