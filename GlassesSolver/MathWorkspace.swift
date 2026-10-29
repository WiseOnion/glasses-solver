import Foundation

/// One math photo and everything known about its problems: the workspace the glasses' buttons
/// act on. Explain, Check, Repeat and swipes all use it, so none of them takes a new photo.
struct MathWorkspace {
  let id = UUID()
  /// The photo as it came from the glasses (for history).
  let photo: Data
  /// The JPEG sent with every request about this photo. Always the same bytes, so the
  /// photo's cache entry is read rather than written again.
  let jpeg: Data
  let takenAt = Date()
  /// The complete problems in the photo, in printed order ("4", "5a").
  var labels: [String] = []
  /// Why nothing could be read, when the photo had no complete problem.
  var unclear: String?
  var problems: [String: MathProblem] = [:]
  /// Which of `labels` the buttons act on.
  var index = 0

  var currentLabel: String? { labels.indices.contains(index) ? labels[index] : nil }
  var current: MathProblem? { currentLabel.flatMap { problems[$0] } }
}

/// One problem in a math photo.
struct MathProblem: Equatable {
  enum Status: Equatable {
    case preparing
    case ready
    /// Claude couldn't solve it; another swipe to it, or Explain, tries again.
    case failed
  }

  var status = Status.preparing
  /// What the problem asks, in a few words, so a misread photo shows on the phone.
  var question = ""
  /// The final answer, as it's spoken.
  var answer = ""
  /// A few sentences for the Explain button.
  var explanation = ""
  /// True when the photo shows the listener's own handwritten work on it, so Check marks
  /// their work instead of re-checking the app's answer.
  var ownWork = false
  /// The written solution's pen lines ("Write: ... || LaTeX"), for the phone.
  var work: [String] = []
  /// The spoken result of Check: "Correct. ...", "Incorrect. ..." or "Unclear. ...".
  var check: String?

  /// The answer and work as text, for a request that needs them (Check, Explain).
  var solution: String {
    (["Answer: \(answer)"] + work).joined(separator: "\n")
  }

  /// The problem as the written answer page reads it: its label, then its pen lines.
  func written(label: String) -> String {
    let lines = work.isEmpty ? ["Sentence: \(answer)"] : work
    return (["Problem: \(label)"] + lines).joined(separator: "\n")
  }

  /// The problem for the history screen and the phone: what it asks, the answer, the
  /// explanation and check when there are any, then the written work.
  func summary(label: String) -> String {
    var lines = ["Problem: \(label)"]
    if !question.isEmpty { lines.append("Question: \(question)") }
    if !answer.isEmpty { lines.append("The answer: \(answer)") }
    if !explanation.isEmpty { lines.append("Why: \(explanation)") }
    if let check { lines.append("Check: \(check)") }
    return (lines + work).joined(separator: "\n")
  }
}

/// A math reply, in the shape the system prompt asks for ("Problems:", "Problem:",
/// "Question:", "Answer:", "Explain:", "Own work:", "Work:" and pen lines), or a Check's
/// "Verdict:" line. Read from the complete lines that have arrived so far, so it can be
/// read again as more comes.
struct MathReply: Equatable {
  var labels: [String] = []
  var unclear: String?
  var label: String?
  var question = ""
  var answer = ""
  var explanation = ""
  var ownWork = false
  var work: [String] = []
  var verdict: String?

  @MainActor
  static func parse(_ text: String) -> MathReply {
    var reply = MathReply()
    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard let colon = line.firstIndex(of: ":") else { continue }
      let tag = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      switch tag {
      case "problems": reply.labels = labels(in: value)
      case "unclear": reply.unclear = value.isEmpty ? nil : value
      case "problem": reply.label = Speaker.problemLabel(in: line)
      case "question": reply.question = value
      case "answer": reply.answer = Speaker.spokenPart(value)
      case "explain": reply.explanation = value
      case "own work": reply.ownWork = value.lowercased().hasPrefix("yes")
      case "verdict": reply.verdict = value.isEmpty ? nil : value
      case "write", "sentence", "mark", "continue": reply.work.append(line)
      default: break
      }
    }
    return reply
  }

  /// "4, 5 and 6" as ["4", "5", "6"].
  static func labels(in list: String) -> [String] {
    list.replacingOccurrences(of: " and ", with: ", ")
      .components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "."))) }
      .filter { !$0.isEmpty }
  }
}
