import SwiftUI
import WebKit

/// An answer as a student would write it on paper: each problem's lines in written math (the
/// LaTeX Claude adds after "||" on each pen line, which is shown but never spoken), one step
/// per line with the equals signs lined up, cross-outs drawn through, the answer boxed, and
/// the step sentences as short notes in the margin of the work.
///
/// The steps go to the page as data (`pageData`), and the page builds them with plain text
/// nodes for MathJax to typeset, so nothing in an answer is ever read as HTML.
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

  /// The steps for the page, as JSON, with the line being said marked.
  func pageData(now: (problem: String, line: Int)?) -> String {
    let nowProblem = now.flatMap { now in problems.lastIndex { $0.label == now.problem } }
    let data: [[String: Any]] = problems.enumerated().compactMap { index, problem in
      guard !problem.lines.isEmpty else { return nil }
      let lines: [[String: Any]] = problem.lines.map { line in
        var step: [String: Any] = [
          "number": line.number, "words": line.words, "boxed": line.boxed,
          "now": index == nowProblem && line.number == now?.line,
        ]
        if let note = line.note { step["note"] = note }
        if let math = line.math {
          if let parts = Self.alignedParts(math) {
            step["left"] = parts.left
            step["right"] = parts.right
          } else {
            step["whole"] = math
          }
        }
        return step
      }
      return ["label": problem.label, "lines": lines]
    }
    guard let json = try? JSONSerialization.data(withJSONObject: data) else { return "[]" }
    return String(decoding: json, as: UTF8.self)
  }

  /// The page the steps are shown on: slightly off-white paper with faint ruling and a margin
  /// line, dark ink, one step per row, equals signs in one column. Long lines scroll sideways
  /// rather than shrink. MathJax (with \cancel for cross-outs) typesets the math, keeping its
  /// own spacing so fractions, roots and matrices get the height they need.
  static let page = #"""
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script>
    MathJax = {
      tex: { inlineMath: [['\\(', '\\)']], packages: {'[+]': ['cancel']} },
      loader: { load: ['[tex]/cancel'] },
      chtml: { scale: 1.1, mtextInheritFont: false }
    };
    function tex(latex) { return '\\(\\displaystyle ' + latex + '\\)'; }
    function cell(className, text) {
      var element = document.createElement('div');
      element.className = className;
      if (text) element.textContent = text;
      return element;
    }
    function render(json) {
      var problems = JSON.parse(json);
      var page = document.getElementById('page');
      page.textContent = '';
      if (!problems.length) {
        page.appendChild(cell('empty', 'The written answer shows here as it comes in.'));
      }
      problems.forEach(function (problem) {
        if (problem.label) page.appendChild(cell('problem', 'Problem ' + problem.label));
        var work = cell('work');
        work.setAttribute('role', 'list');
        problem.lines.forEach(function (line) {
          if (line.note) work.appendChild(cell('note', line.note));
          var marks = (line.now ? ' now' : '') + (line.boxed ? ' boxed' : '');
          var number = cell('number' + marks, line.number + '.');
          number.setAttribute('role', 'listitem');
          number.setAttribute('aria-label', 'Line ' + line.number + ': ' + line.words);
          if (line.now) number.id = 'now';
          work.appendChild(number);
          if (line.whole !== undefined) {
            work.appendChild(cell('whole' + marks, tex(line.whole)));
          } else if (line.right !== undefined) {
            work.appendChild(cell('left' + marks, line.left ? tex(line.left) : ''));
            work.appendChild(cell('right' + marks, tex(line.right)));
          } else {
            work.appendChild(cell('whole words' + marks, line.words));
          }
        });
        page.appendChild(work);
      });
      var show = function () {
        var now = document.getElementById('now');
        if (now) now.scrollIntoView({ block: 'center', behavior: 'smooth' });
      };
      if (window.MathJax && MathJax.typesetPromise) {
        if (MathJax.typesetClear) MathJax.typesetClear([page]);
        MathJax.typesetPromise([page]).then(show).catch(show);
      } else {
        show();
      }
    }
    </script>
    <script defer src="https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-chtml.js"></script>
    <style>
    :root { --ink: #1b2233; --faint: #6b7385; --rule: #e3e7ee; --margin: #edc6c6; }
    body { margin: 0; background: #fffef9; color: var(--ink);
      font-family: "Noteworthy", "Marker Felt", sans-serif; -webkit-text-size-adjust: none; }
    #page { padding: 14px 14px 40px 46px; min-height: 100vh; box-sizing: border-box;
      background-image: linear-gradient(to right, transparent 34px, var(--margin) 34px,
          var(--margin) 35px, transparent 35px),
        repeating-linear-gradient(to bottom, transparent 0, transparent 35px, var(--rule) 35px,
          var(--rule) 36px); }
    .problem { font-size: 17px; font-weight: bold; margin: 18px 0 6px; }
    .problem:first-child { margin-top: 0; }
    .work { display: grid; grid-template-columns: max-content max-content max-content;
      align-items: center; column-gap: 0; row-gap: 6px; overflow-x: auto;
      padding-bottom: 4px; }
    .note { grid-column: 1 / -1; font-size: 14px; color: var(--faint); margin-top: 6px; }
    .number { font-size: 12px; color: var(--faint); padding-right: 8px;
      font-family: -apple-system, sans-serif; justify-self: end; margin-left: -34px; width: 26px;
      text-align: right; }
    .left { justify-self: end; text-align: right; padding: 3px 0 3px 4px; }
    .right { justify-self: start; padding: 3px 4px 3px 0.25em; }
    .whole { grid-column: 2 / -1; justify-self: start; padding: 3px 4px; }
    .words { font-size: 18px; }
    .now:not(.number) { background: #f4f1e4; }
    .left.boxed, .right.boxed, .whole.boxed { border-top: 1.5px solid var(--ink);
      border-bottom: 1.5px solid var(--ink); }
    .left.boxed { border-left: 1.5px solid var(--ink); padding-left: 8px; }
    .right.boxed, .whole.boxed { border-right: 1.5px solid var(--ink); padding-right: 8px; }
    .whole.boxed { border-left: 1.5px solid var(--ink); padding-left: 8px; }
    .empty { color: var(--faint); padding-top: 8px; }
    </style></head>
    <body><main id="page" aria-label="Written answer"></main></body></html>
    """#
}

/// Shows a `WrittenAnswer` on the phone. The page is loaded once; new lines replace its
/// content, so the view doesn't flash while the answer arrives.
struct WrittenAnswerView: UIViewRepresentable {
  /// The steps, from `WrittenAnswer.pageData`.
  let data: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.navigationDelegate = context.coordinator
    view.isOpaque = false
    view.backgroundColor = .clear
    context.coordinator.view = view
    view.loadHTMLString(WrittenAnswer.page, baseURL: nil)
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.show(data)
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate {
    weak var view: WKWebView?
    private var loaded = false
    private var shown: String?
    private var pending: String?

    func show(_ data: String) {
      guard data != shown else { return }
      pending = data
      flush()
    }

    private func flush() {
      guard loaded, let view, let pending else { return }
      shown = pending
      self.pending = nil
      // Passed as a JavaScript string, then parsed on the page.
      let argument = (try? JSONSerialization.data(withJSONObject: pending, options: .fragmentsAllowed))
        .map { String(decoding: $0, as: UTF8.self) } ?? "\"[]\""
      view.evaluateJavaScript("render(\(argument))", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      flush()
    }
  }
}
