import SwiftUI
import WebKit

/// An answer as it would look written on the page: each problem's lines in written math (the
/// LaTeX Claude adds after "||" on each pen line, which is shown but never spoken), with
/// cross-outs, the boxed answer, and the step sentences as short notes. Plain black on white,
/// like a worked answer on a test page.
struct WrittenAnswer: Equatable {
  struct Line: Equatable {
    let number: Int
    /// The line in LaTeX, or nil when the answer didn't include it (then `words` are shown).
    var math: String?
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
        guard let last = written.problems[index].lines.indices.last,
          written.problems[index].lines[last].math == nil
        else { continue }
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

  /// The page's content: one block per line, with an id on the line being said now.
  func html(now: (problem: String, line: Int)?) -> String {
    let nowProblem = now.flatMap { now in problems.lastIndex { $0.label == now.problem } }
    var out = ""
    for (index, problem) in problems.enumerated() where !problem.lines.isEmpty {
      if !problem.label.isEmpty { out += "<h2>Problem \(Self.escape(problem.label))</h2>" }
      for line in problem.lines {
        if let note = line.note { out += "<div class=\"note\">\(Self.escape(note))</div>" }
        let isNow = index == nowProblem && line.number == now?.line
        let content = line.math.map { "\\(\\displaystyle \(Self.escape($0))\\)" } ?? Self.escape(line.words)
        out += "<div class=\"step\(isNow ? " now" : "")\"\(isNow ? " id=\"now\"" : "")>"
          + "<span class=\"number\">\(line.number).</span>"
          + "<span class=\"math\(line.boxed ? " boxed" : "")\">\(content)</span></div>"
      }
    }
    return out
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// The page the lines are shown in. MathJax (with \cancel for cross-outs) typesets the math.
  static let page = #"""
    <!DOCTYPE html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <script>
    MathJax = {
      tex: { inlineMath: [['\\(', '\\)']], packages: {'[+]': ['cancel']} },
      loader: { load: ['[tex]/cancel'] },
      chtml: { scale: 1.1 }
    };
    function render(html) {
      var page = document.getElementById('page');
      page.innerHTML = html || '<p class="empty">The written answer shows here as it comes in.</p>';
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
    body { margin: 0; padding: 16px; background: #fff; color: #000;
      font-family: "Noteworthy", "Marker Felt", sans-serif; -webkit-text-size-adjust: none; }
    h2 { font-size: 18px; font-weight: bold; margin: 18px 0 8px; border-bottom: 1px solid #000; }
    h2:first-child { margin-top: 0; }
    .note { font-size: 14px; color: #555; margin: 10px 0 2px 30px; }
    .step { display: flex; align-items: center; gap: 10px; min-height: 40px; font-size: 20px;
      overflow-x: auto; padding: 2px 4px; }
    .step.now { background: #f0f0f0; }
    .number { min-width: 20px; font-size: 13px; color: #555; font-family: -apple-system, sans-serif; }
    .math { white-space: nowrap; }
    .boxed { border: 2px solid #000; padding: 4px 10px; }
    .empty { color: #777; }
    </style></head>
    <body><div id="page"></div></body></html>
    """#
}

/// Shows a `WrittenAnswer` on the phone. The page is loaded once; new lines replace its
/// content, so the view doesn't flash while the answer arrives.
struct WrittenAnswerView: UIViewRepresentable {
  let html: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.navigationDelegate = context.coordinator
    view.backgroundColor = .white
    view.isOpaque = true
    context.coordinator.view = view
    view.loadHTMLString(WrittenAnswer.page, baseURL: nil)
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.show(html)
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate {
    weak var view: WKWebView?
    private var loaded = false
    private var shown: String?
    private var pending: String?

    func show(_ html: String) {
      guard html != shown else { return }
      pending = html
      flush()
    }

    private func flush() {
      guard loaded, let view, let pending else { return }
      shown = pending
      self.pending = nil
      let argument = (try? JSONSerialization.data(withJSONObject: pending, options: .fragmentsAllowed))
        .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
      view.evaluateJavaScript("render(\(argument))", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      flush()
    }
  }
}
