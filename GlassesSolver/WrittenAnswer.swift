import SwiftUI
import UIKit
import WebKit

/// An answer as a student would write it on paper: each problem's lines in written math (the
/// LaTeX Claude adds after "||" on each pen line, which is shown but never spoken), one step
/// per line with the equals signs lined up, cross-outs drawn through, the answer boxed, and
/// the step sentences as short notes in the margin of the work.
///
/// The steps go to the page as data (`pageData`), and the page builds them as text and
/// typesets each piece of math with KaTeX, so nothing in an answer is ever read as HTML.
struct WrittenAnswer: Equatable {
  struct Line: Equatable {
    let number: Int
    /// The line in LaTeX, or nil when the answer didn't include it (then `words` are shown).
    var math: String?
    /// The line as it's spoken, for screen readers and when there's no math.
    var words: String
    var boxed = false
    /// The step sentence said before this line ("Now distribute the 7.").
    var note: String?
  }

  struct Problem: Equatable {
    let label: String
    var lines: [Line] = []
    /// A multiple-choice question (its answer is a letter), headed "Question", not "Problem".
    var isQuestion = false
  }

  var problems: [Problem] = []

  /// True when there's no written math to show (an old answer, or none of it has arrived).
  var isEmpty: Bool { !problems.contains { $0.lines.contains { $0.math != nil } } }

  /// The written answer in `answer` (the text Claude sent, complete lines only).
  @MainActor
  static func parse(_ answer: String) -> WrittenAnswer {
    var written = WrittenAnswer()
    var number = 0
    var note: String?
    func currentProblem() -> Int {
      if written.problems.isEmpty { written.problems.append(Problem(label: "")) }
      return written.problems.count - 1
    }
    for raw in answer.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let lower = line.lowercased()
      let spoken = Speaker.spokenPart(line)
      let math = Self.mathPart(line)
      if let label = Speaker.problemLabel(in: spoken) {
        written.problems.append(Problem(label: label))
        number = (Speaker.startingLine(in: label) ?? 1) - 1
        note = nil
      } else if lower.hasPrefix("write:") || lower.hasPrefix("sentence:") {
        number += 1
        let index = currentProblem()
        written.problems[index].lines.append(
          Line(number: number, math: math, words: Self.afterTag(spoken), note: note))
        note = nil
      } else if lower.hasPrefix("answer:") {
        // A multiple-choice answer: the letter and the choice, boxed like a final answer.
        number += 1
        let index = currentProblem()
        written.problems[index].isQuestion = true
        written.problems[index].lines.append(
          Line(number: number, math: math, words: Self.afterTag(spoken), boxed: true))
      } else if lower.hasPrefix("continue:") {
        let index = currentProblem()
        guard let last = written.problems[index].lines.indices.last else { continue }
        written.problems[index].lines[last].words += " " + Self.afterTag(spoken)
      } else if lower.hasPrefix("mark:") {
        let index = currentProblem()
        // "|| line 5: ..." is line 5 again, with what's crossed out in \cancel.
        if let math, let target = Self.lineNumber(in: math), let colon = math.firstIndex(of: ":"),
          let at = written.problems[index].lines.lastIndex(where: { $0.number == target })
        {
          written.problems[index].lines[at].math = String(math[math.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        }
        if lower.contains("box around"), let target = Self.lineNumber(in: lower),
          let at = written.problems[index].lines.lastIndex(where: { $0.number == target })
        {
          written.problems[index].lines[at].boxed = true
        }
      } else if lower.hasPrefix("first") || lower.hasPrefix("now") || lower.hasPrefix("next") {
        note = spoken
      }
    }
    return written
  }

  /// The LaTeX after "||", if the line has any.
  static func mathPart(_ line: String) -> String? {
    guard let marker = line.range(of: "||") else { return nil }
    let math = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
    return math.isEmpty ? nil : math
  }

  private static func afterTag(_ line: String) -> String {
    guard let colon = line.firstIndex(of: ":") else { return line }
    return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
  }

  /// N in "line N".
  private static func lineNumber(in text: String) -> Int? {
    guard let range = text.range(of: #"(?<=line )\d+"#, options: [.regularExpression, .caseInsensitive])
    else { return nil }
    return Int(text[range])
  }

  // MARK: - Lining up the equals signs

  /// Relations a student lines up from one line to the next.
  private static let relations: Set<String> = ["=", "<", ">"]
  private static let relationCommands: Set<String> = [
    "le", "leq", "ge", "geq", "ne", "neq", "approx", "equiv", "lt", "gt",
  ]

  /// A line split at its first relation that isn't inside braces, \left...\right or an
  /// environment: "2x + 7 = 19" is ("2x + 7", "= 19"), and "= x + 1" is ("", "= x + 1").
  /// nil when there's no such relation (the line is a single expression). The split is only
  /// where the line is shown; the math itself is untouched.
  static func alignedParts(_ latex: String) -> (left: String, right: String)? {
    let characters = Array(latex)
    var depth = 0
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        var end = index + 1
        while end < characters.count, characters[end].isLetter { end += 1 }
        let name = String(characters[(index + 1)..<end])
        switch name {
        case "left", "begin": depth += 1
        case "right", "end": depth = max(0, depth - 1)
        default:
          if depth == 0, relationCommands.contains(name) { return split(characters, at: index) }
        }
        // A command without letters ("\{", "\,") is two characters.
        index = name.isEmpty ? index + 2 : end
        continue
      }
      if character == "{" { depth += 1 }
      if character == "}" { depth = max(0, depth - 1) }
      if depth == 0, relations.contains(String(character)) { return split(characters, at: index) }
      index += 1
    }
    return nil
  }

  private static func split(_ characters: [Character], at index: Int) -> (left: String, right: String) {
    (
      String(characters[..<index]).trimmingCharacters(in: .whitespaces),
      String(characters[index...]).trimmingCharacters(in: .whitespaces)
    )
  }

  // MARK: - The page

  /// The steps for the page, as JSON, with the line being said marked. Only the math goes to
  /// the page (no step sentences or other prose): a line split at its relation so the signs
  /// line up, plus any rows it continues onto (`more`), where Claude broke a long line with \\.
  func pageData(now: (problem: String, line: Int)?) -> String {
    let nowProblem = now.flatMap { now in problems.lastIndex { $0.label == now.problem } }
    let data: [[String: Any]] = problems.enumerated().compactMap { index, problem in
      guard !problem.lines.isEmpty else { return nil }
      let lines: [[String: Any]] = problem.lines.map { line in
        var step: [String: Any] = [
          "number": line.number, "words": line.words, "boxed": line.boxed,
          "now": index == nowProblem && line.number == now?.line,
        ]
        if let math = line.math {
          let rows = Self.rows(math)
          let first = rows.first ?? math
          if let parts = Self.alignedParts(first) {
            step["left"] = parts.left
            step["right"] = parts.right
          } else {
            step["whole"] = first
          }
          if rows.count > 1 { step["more"] = Array(rows.dropFirst()) }
        }
        return step
      }
      // "part A" is headed "Part A", not "Problem part A".
      let isPart = problem.label.lowercased().hasPrefix("part ")
      return [
        "label": isPart ? String(problem.label.dropFirst(5)) : problem.label,
        "word": isPart ? "Part" : problem.isQuestion ? "Question" : "Problem", "lines": lines,
      ]
    }
    guard let json = try? JSONSerialization.data(withJSONObject: data) else { return "[]" }
    return String(decoding: json, as: UTF8.self)
  }

  /// A line of math cut where Claude broke it with \\ to fit a phone, outside any group or
  /// environment (a \\ inside cases or a matrix is part of it).
  static func rows(_ latex: String) -> [String] {
    let characters = Array(latex)
    var rows: [String] = []
    var depth = 0
    var start = 0
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        if index + 1 < characters.count, characters[index + 1] == "\\" {
          if depth == 0 {
            rows.append(String(characters[start..<index]))
            start = index + 2
          }
          index += 2
          continue
        }
        var end = index + 1
        while end < characters.count, characters[end].isLetter { end += 1 }
        let name = String(characters[(index + 1)..<end])
        if name == "left" || name == "begin" { depth += 1 }
        if name == "right" || name == "end" { depth = max(0, depth - 1) }
        index = name.isEmpty ? index + 2 : end
        continue
      }
      if character == "{" { depth += 1 }
      if character == "}" { depth = max(0, depth - 1) }
      index += 1
    }
    rows.append(String(characters[start...]))
    return rows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// The page the steps are shown on (Math/written.html, with KaTeX beside it), loaded from
  /// the app itself so it works offline and the math fonts load from the phone.
  static var pageURL: URL? { Bundle.main.url(forResource: "written", withExtension: "html", subdirectory: "Math") }
}

/// Shows a `WrittenAnswer` on the phone. The page is loaded once; new lines replace its
/// content, so the view doesn't flash while the answer arrives.
struct WrittenAnswerView: UIViewRepresentable {
  /// The steps, from `WrittenAnswer.pageData`.
  let data: String
  /// Shown instead when there are no steps ("Working on it...").
  var emptyMessage = "No written answer yet."

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.navigationDelegate = context.coordinator
    view.isOpaque = true
    view.backgroundColor = .black
    view.scrollView.backgroundColor = .black
    view.underPageBackgroundColor = .black
    view.overrideUserInterfaceStyle = .dark
    context.coordinator.view = view
    if let page = WrittenAnswer.pageURL {
      // Read access to the whole folder, so KaTeX's script, style and fonts load from the app.
      view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    } else {
      diag("written", "the written-answer page is missing from the app")
    }
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.show(data, emptyMessage: emptyMessage)
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate {
    weak var view: WKWebView?
    private var loaded = false
    private var shown: String?
    private var pending: String?

    func show(_ data: String, emptyMessage: String) {
      let call = "render(\(Self.javaScriptString(data)), \(Self.javaScriptString(emptyMessage)))"
      guard call != shown else { return }
      pending = call
      flush()
    }

    private func flush() {
      guard loaded, let view, let pending else { return }
      shown = pending
      self.pending = nil
      view.evaluateJavaScript(pending) { _, error in
        if let error { diag("written", "the page couldn't show the answer: \(ErrorDetail.describe(error))") }
      }
    }

    /// A string as a JavaScript string literal (JSON's quoting is valid JavaScript).
    private static func javaScriptString(_ text: String) -> String {
      (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed))
        .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      flush()
    }
  }
}

/// The written answer: a clean worksheet on near-black, the heart of the app. Live, it follows
/// the current photo: the problem and its photo at the top, the work, then the answer exactly
/// as the glasses say it, with the same actions as the glasses along the bottom. A saved answer
/// opens in the same layout.
struct WrittenAnswerScreen: View {
  private let model: AppModel?
  private let saved: Saved?
  @Environment(\.dismiss) private var dismiss
  @State private var showPhoto = false

  /// An answer from History.
  struct Saved {
    let answer: String
    let photo: UIImage?
    let title: String
    let onReplay: (() -> Void)?
  }

  /// The current answer, following along as it arrives and as it's read.
  init(model: AppModel) {
    self.model = model
    saved = nil
  }

  /// A saved answer.
  init(answer: String, photo: UIImage? = nil, title: String = "Written Answer", onReplay: (() -> Void)? = nil) {
    model = nil
    saved = Saved(answer: answer, photo: photo, title: title, onReplay: onReplay)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        header
        WrittenAnswerView(data: data, emptyMessage: emptyMessage)
        result
        thumbnail
      }
      .background(Color.black.ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Back", systemImage: "chevron.left") { dismiss() }
        }
        if let model {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Stop", systemImage: "stop.fill") { model.stopSpeaking() }
          }
          ToolbarItemGroup(placement: .bottomBar) {
            if model.subject == .math {
              Button("Previous", systemImage: "chevron.left") { model.moveProblem(by: -1) }
                .disabled((model.workspace?.index ?? 0) == 0)
              Spacer()
              Button("Explain", systemImage: "text.bubble") { model.explainCurrentProblem() }
              Button("Repeat", systemImage: "arrow.counterclockwise") { model.repeatAnswer() }
              Button("Check", systemImage: "checkmark.circle") { model.checkCurrentProblem() }
                .disabled(model.isChecking)
              Spacer()
              Button("Next", systemImage: "chevron.right") { model.moveProblem(by: 1) }
                .disabled(model.workspace.map { $0.index >= $0.labels.count - 1 } ?? true)
            } else {
              Button("Previous", systemImage: "chevron.left") { model.replayQuestion(by: -1) }
              Spacer()
              Button("Repeat", systemImage: "arrow.counterclockwise") { model.repeatWriteLine() }
              Spacer()
              Button("Next", systemImage: "chevron.right") { model.replayQuestion(by: 1) }
            }
          }
        } else if let onReplay = saved?.onReplay {
          ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Button("Play Again", systemImage: "play.fill", action: onReplay)
              .labelStyle(.titleAndIcon)
            Spacer()
          }
        }
      }
      .sheet(isPresented: $showPhoto) { PhotoDetailView(image: photo) }
    }
    .preferredColorScheme(.dark)
  }

  // MARK: - Top: the photo and what the problem asks

  @ViewBuilder
  private var header: some View {
    if !subtitle.isEmpty {
      HStack(alignment: .center, spacing: 12) {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }

  private var photo: UIImage? { model?.lastPhoto ?? saved?.photo }

  private var title: String {
    guard let model else { return saved?.title ?? "Written Answer" }
    switch model.phase {
    case .capturing: return "Taking Photo…"
    case .thinking where model.subject == .chemistry || model.currentProblem?.problem?.answer.isEmpty != false:
      return "Solving…"
    default: break
    }
    guard model.subject == .math, let space = model.workspace, space.labels.count > 1 else { return "Answer" }
    return "Answer · \(space.index + 1) of \(space.labels.count)"
  }

  private var subtitle: String {
    guard let model else { return Self.savedLine("Question: ", in: saved?.answer ?? "") ?? "" }
    if model.subject == .chemistry {
      let names = AppModel.questions(in: model.shownAnswer).map(\.label)
      return names.isEmpty ? "" : (names.count == 1 ? "Question " : "Questions ") + names.joined(separator: ", ")
    }
    return model.currentProblem?.problem?.question ?? ""
  }

  // MARK: - Middle: the work

  /// The work to show: the same parsed lines the voice uses. While an answer arrives, only its
  /// complete lines; while a new photo is being worked on, none.
  private var data: String {
    guard let model else { return WrittenAnswer.parse(saved?.answer ?? "").pageData(now: nil) }
    let text = model.phase == .thinking ? ClaudeClient.completeLines(model.shownAnswer) : model.shownAnswer
    return WrittenAnswer.parse(text).pageData(now: model.linePosition.map { ($0.problem, $0.line) })
  }

  private var emptyMessage: String {
    guard let model else { return "This answer has no written work." }
    if model.phase != .idle { return "Working on it\u{2026}" }
    return model.shownAnswer.isEmpty && model.currentProblem == nil
      ? "No answer yet. Take a photo of a problem." : "This answer has no written work."
  }

  // MARK: - Bottom: the answer, as it's spoken

  @ViewBuilder
  private var result: some View {
    let lines = resultLines
    if !lines.answer.isEmpty || !lines.notes.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if !lines.answer.isEmpty {
            Text(lines.answer)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.white)
          }
          ForEach(lines.notes, id: \.self) { note in
            Text(note)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      }
      .frame(maxHeight: 200)
      .fixedSize(horizontal: false, vertical: true)
      .background(Color(.secondarySystemBackground))
    }
  }

  /// The spoken answer, then the explanation and check result, from the same stored problem
  /// the voice reads (math). Chemistry's answers are on the page itself.
  private var resultLines: (answer: String, notes: [String]) {
    guard let model else {
      let text = saved?.answer ?? ""
      return (
        Self.savedLine("The answer: ", in: text) ?? "",
        [Self.savedLine("Why: ", in: text), Self.savedLine("Check: ", in: text)].compactMap { $0 }
      )
    }
    guard model.subject == .math, let problem = model.currentProblem?.problem else { return ("", []) }
    var notes: [String] = []
    if !problem.explanation.isEmpty { notes.append(problem.explanation) }
    if let check = problem.check { notes.append("Check: " + check) }
    return (problem.answer, notes)
  }

  private static func savedLine(_ prefix: String, in text: String) -> String? {
    text.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
  }

  // MARK: - Controls

  /// The photo, small, at the bottom leading corner: tap to see it full screen.
  @ViewBuilder
  private var thumbnail: some View {
    if let photo {
      HStack {
        Button {
          showPhoto = true
        } label: {
          Image(uiImage: photo)
            .resizable()
            .scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .accessibilityLabel("Photo. Opens it full screen.")
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }
}
