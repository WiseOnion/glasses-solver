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
/// "Verdict:" line. It can be read again as more arrives.
///
/// A line with no known tag carries on the field before it, so an answer written over two
/// lines is kept whole. That also means an answer isn't finished when its first line is: it's
/// finished when the next tagged line starts, or the reply ends (`answerIfComplete`).
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
  /// The tags the reply used, in order (for the log; no content).
  var tagsSeen: [String] = []
  /// Fields no more lines can be added to.
  var closed: Set<String> = []

  /// The answer, once nothing more can be added to it; nil while it may still go on.
  var answerIfComplete: String? { closed.contains("answer") && !answer.isEmpty ? answer : nil }
  /// The explanation, once nothing more can be added to it.
  var explanationIfComplete: String? {
    closed.contains("explain") && !explanation.isEmpty ? explanation : nil
  }

  private static let tags: Set<String> = [
    "problems", "unclear", "problem", "question", "answer", "explain", "own work", "work", "verdict", "write",
    "sentence", "mark", "continue",
  ]
  /// Fields that a following untagged line carries on.
  private static let continuing: Set<String> = ["unclear", "question", "answer", "explain", "verdict"]

  /// `complete` is false while the reply is still arriving: then its last line may be
  /// unfinished, so it counts only for its tag (which ends the field before it), never for
  /// its text.
  @MainActor
  static func parse(_ text: String, complete: Bool = true) -> MathReply {
    var reply = MathReply()
    var lines = text.components(separatedBy: "\n")
    let unfinished = complete ? nil : lines.removeLast()
    var open: String?
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, line != "Done." else { continue }
      guard let match = tagged(line) else {
        if let open { reply.carryOn(open, with: line) }
        continue
      }
      let (tag, value) = match
      if let open { reply.closed.insert(open) }
      open = continuing.contains(tag) ? tag : nil
      reply.tagsSeen.append(tag)
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
    // The next tag has started, or nothing more is coming: the open field is finished.
    if let open, complete || unfinished.flatMap({ tagged($0.trimmingCharacters(in: .whitespaces)) }) != nil {
      reply.closed.insert(open)
    }
    return reply
  }

  /// The tag and its value, if `line` starts with a tag this reply uses.
  private static func tagged(_ line: String) -> (String, String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let tag = line[..<colon].lowercased()
    guard tags.contains(tag) else { return nil }
    return (tag, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
  }

  /// Adds a line with no tag to the field it continues.
  private mutating func carryOn(_ field: String, with line: String) {
    switch field {
    case "unclear": unclear = [unclear, line].compactMap { $0 }.joined(separator: " ")
    case "question": question += " " + line
    case "answer": answer += " " + Speaker.spokenPart(line)
    case "explain": explanation += " " + line
    case "verdict": verdict = [verdict, line].compactMap { $0 }.joined(separator: " ")
    default: break
    }
  }

  /// Why a reply can't be used, so the log (and what's said) tells these apart.
  enum Failure: String, Equatable {
    /// Claude said it couldn't read the photo (an Unclear line).
    case unreadable = "photo-unreadable"
    /// Text came back with none of the expected tags, so nothing could be parsed.
    case unparseable = "reply-unparseable"
    /// An answer, but no Problem line saying which problem it's for.
    case missingProblemLine = "reply-missing-problem-line"
    /// The tags were there, but no answer.
    case noAnswer = "reply-no-answer"
  }

  /// Why this reply can't be used as the answer to `asked` (nil: a photo's first request,
  /// which has to name its problem), or nil if it can.
  func failure(asked: String?) -> Failure? {
    if !answer.isEmpty { return asked == nil && label == nil ? .missingProblemLine : nil }
    if unclear != nil { return .unreadable }
    return tagsSeen.isEmpty ? .unparseable : .noAnswer
  }

  /// "4, 5 and 6" as ["4", "5", "6"].
  static func labels(in list: String) -> [String] {
    list.replacingOccurrences(of: " and ", with: ", ")
      .components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "."))) }
      .filter { !$0.isEmpty }
  }
}
