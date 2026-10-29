import Darwin
import SwaTex
import SwaTexRender
import SwiftMath
import UIKit
import WebKit
import XCTest
import iosMath

/// Renders every case in `Corpus` with each candidate renderer, at the written answer's size
/// (20 pt, white on black, 360 points wide), and writes for each renderer:
/// - `<renderer>.png`: every case, with a red line at the 360-point edge so overflow shows;
/// - a row per case in `results.md`: status, width, render time.
/// Output goes to EVAL_DIR (TEST_RUNNER_EVAL_DIR in CI).
@MainActor
final class RendererEvalTests: XCTestCase {
  static let fontSize: CGFloat = 20
  static let width: CGFloat = 360
  static var rows: [String: [Row]] = [:]
  static var notes: [String] = []

  struct Row {
    let image: UIImage?
    /// ok, error (the renderer reported it), fallback (shown as source text), blank.
    let status: String
    let detail: String
    let milliseconds: Double
  }

  override class func tearDown() {
    MainActor.assumeIsolated { writeReport() }
    super.tearDown()
  }

  // MARK: - Renderers

  func test1SwaTex() throws {
    try run("SwaTex") { latex in
      do {
        let list = try SwaTexEngine.displayList(for: latex, style: .display, color: .white)
        let image = SwaTexRender.ImageRenderer.image(
          for: list, options: RenderOptions(fontSize: Self.fontSize, padding: 2), displayScale: 2)
        return Row(image: image.map { UIImage(cgImage: $0, scale: 2, orientation: .up) }, status: "ok", detail: "", milliseconds: 0)
      } catch {
        return Row(image: nil, status: "error", detail: String(describing: error), milliseconds: 0)
      }
    }
  }

  func test2SwiftMath() throws {
    try run("SwiftMath") { latex in
      let label = SwiftMath.MTMathUILabel()
      label.latex = latex
      label.fontSize = Self.fontSize
      label.textColor = .white
      label.labelMode = .display
      label.displayErrorInline = true
      // Its line wrapping: lay out within the answer's width.
      label.preferredMaxLayoutWidth = Self.width
      let size = label.sizeThatFits(CGSize(width: Self.width, height: .greatestFiniteMagnitude))
      label.frame = CGRect(origin: .zero, size: size)
      label.layoutIfNeeded()
      if let error = label.error {
        return Row(image: Self.snapshot(label), status: "error", detail: error.localizedDescription, milliseconds: 0)
      }
      return Row(image: Self.snapshot(label), status: "ok", detail: "", milliseconds: 0)
    }
  }

  func test3iosMath() throws {
    try run("iosMath") { latex in
      let label = iosMath.MTMathUILabel()
      label.latex = latex
      label.fontSize = Self.fontSize
      label.textColor = .white
      label.mode = .display
      label.displayErrorInline = true
      let size = label.sizeThatFits(CGSize(width: Self.width, height: .greatestFiniteMagnitude))
      label.frame = CGRect(origin: .zero, size: size)
      label.layoutIfNeeded()
      if let error = label.error {
        return Row(image: Self.snapshot(label), status: "error", detail: error.localizedDescription, milliseconds: 0)
      }
      return Row(image: Self.snapshot(label), status: "ok", detail: "", milliseconds: 0)
    }
  }

  /// The app's renderer today: KaTeX 0.16.11 in a web view, through written.html's own
  /// `math()` (which shows the LaTeX as text when KaTeX can't read it).
  func test4CurrentKaTeX() async throws {
    let page = try XCTUnwrap(Bundle.main.url(forResource: "written", withExtension: "html", subdirectory: "Math"))
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 400))
    web.isOpaque = false
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = web.frame
    window.addSubview(web)
    window.isHidden = false
    web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    for _ in 0..<50 where (try? await web.evaluateJavaScript("typeof katex")) as? String != "object" {
      try await Task.sleep(for: .milliseconds(100))
    }
    let setup = """
      document.body.innerHTML = '<div id="eval" style="display:inline-block;color:#fff;font-size:\(Int(Self.fontSize))px;padding:2px"></div>';
      document.body.style.background = 'transparent'; document.body.style.margin = '0';
      """
    _ = try await web.evaluateJavaScript(setup)
    var rows: [Row] = []
    let started = Self.footprint()
    for item in Corpus.cases {
      let script = """
        (function () {
          var e = document.getElementById('eval'); e.textContent = '';
          var t = performance.now(); math(\(Self.jsString(item.latex)), e); var ms = performance.now() - t;
          var r = e.getBoundingClientRect();
          return [ms, r.width, r.height, e.querySelector('.katex') ? 1 : 0];
        })()
        """
      let result = try await web.evaluateJavaScript(script) as? [Double] ?? [0, 0, 0, 0]
      let rect = CGRect(x: 0, y: 0, width: max(result[1], 1), height: max(result[2], 1))
      web.frame.size = CGSize(width: max(Self.width, rect.width), height: max(rect.height, 1))
      let config = WKSnapshotConfiguration()
      config.rect = rect
      let image = try? await web.takeSnapshot(configuration: config)
      rows.append(Row(
        image: image, status: result[3] == 1 ? "ok" : "fallback",
        detail: result[3] == 1 ? "" : "shown as source text", milliseconds: result[0]))
    }
    Self.rows["Current (KaTeX)"] = rows
    Self.notes.append(
      "Current (KaTeX): \(Self.megabytes(Self.footprint() - started)) in the app process; "
        + "WebKit renders in its own process, which this doesn't count.")
  }

  // MARK: - Running and measuring

  private func run(_ name: String, render: (String) throws -> Row) throws {
    let started = Self.footprint()
    var rows: [Row] = []
    for item in Corpus.cases {
      let start = DispatchTime.now()
      let row = try render(item.latex)
      let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
      rows.append(Row(image: row.image, status: row.image == nil && row.status == "ok" ? "blank" : row.status, detail: row.detail, milliseconds: ms))
    }
    // A second pass: what a redraw of the same lines costs (caches warm).
    let again = DispatchTime.now()
    for item in Corpus.cases { _ = try render(item.latex) }
    let warm = Double(DispatchTime.now().uptimeNanoseconds - again.uptimeNanoseconds) / 1_000_000
    Self.rows[name] = rows
    let cold = rows.map(\.milliseconds).reduce(0, +)
    Self.notes.append(
      "\(name): all \(Corpus.cases.count) cases \(String(format: "%.1f", cold)) ms cold, "
        + "\(String(format: "%.1f", warm)) ms again; memory +\(Self.megabytes(Self.footprint() - started)).")
  }

  private static func snapshot(_ view: UIView) -> UIImage? {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
      view.layer.render(in: context.cgContext)
    }
  }

  private static func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
  }

  private static func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  private static func jsString(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text])
    return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
  }

  // MARK: - Report

  private static func writeReport() {
    guard let dir = ProcessInfo.processInfo.environment["EVAL_DIR"] else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let names = ["Current (KaTeX)", "SwaTex", "SwiftMath", "iosMath"].filter { rows[$0] != nil }
    for name in names {
      let png = sheet(name: name, rows: rows[name]!).pngData()
      try? png?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    var md = "| Group | Case | " + names.joined(separator: " | ") + " |\n|---|---|" + names.map { _ in "---|" }.joined() + "\n"
    for (index, item) in Corpus.cases.enumerated() {
      let cells = names.map { name -> String in
        let row = rows[name]![index]
        let width = row.image.map { String(format: "%.0f pt", $0.size.width) } ?? "-"
        let over = (row.image?.size.width ?? 0) > width_ ? " **overflows**" : ""
        let detail = row.detail.isEmpty ? "" : " (\(row.detail.prefix(60)))"
        return "\(row.status)\(detail), \(width)\(over), \(String(format: "%.2f", row.milliseconds)) ms"
      }
      md += "| \(item.group) | \(item.name) | " + cells.joined(separator: " | ") + " |\n"
    }
    md += "\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
    try? md.write(to: URL(fileURLWithPath: dir).appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
  }

  private static var width_: CGFloat { width }

  /// One renderer's cases on a black page: the case name in gray, then the math, with a red
  /// line at the written answer's edge.
  private static func sheet(name: String, rows: [Row]) -> UIImage {
    let pageWidth: CGFloat = 640
    let gap: CGFloat = 10
    let labelHeight: CGFloat = 16
    let heights = rows.map { max($0.image?.size.height ?? 20, 20) + labelHeight + gap }
    let size = CGSize(width: pageWidth, height: heights.reduce(40, +))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      (name as NSString).draw(at: CGPoint(x: 12, y: 10), withAttributes: [
        .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.white,
      ])
      UIColor.systemRed.withAlphaComponent(0.7).setFill()
      context.fill(CGRect(x: 12 + width, y: 36, width: 1, height: size.height - 36))
      var y: CGFloat = 40
      for (index, row) in rows.enumerated() {
        let item = Corpus.cases[index]
        let label = "\(item.group) · \(item.name)" + (row.status == "ok" ? "" : "  [\(row.status)]")
        (label as NSString).draw(at: CGPoint(x: 12, y: y), withAttributes: [
          .font: UIFont.systemFont(ofSize: 11),
          .foregroundColor: row.status == "ok" ? UIColor.gray : UIColor.systemOrange,
        ])
        if let image = row.image {
          image.draw(at: CGPoint(x: 12, y: y + labelHeight))
        }
        y += heights[index]
      }
    }
  }
}
