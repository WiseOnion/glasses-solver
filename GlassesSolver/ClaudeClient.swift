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
  static let system =
    "Your reply is read aloud by text-to-speech. Write plain spoken sentences only: no Markdown, "
    + "bullets, tables, LaTeX, or code. Say math in words when symbols would read badly, "
    + "for example \"x squared\" instead of \"x^2\"."

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
