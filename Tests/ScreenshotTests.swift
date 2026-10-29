import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import GlassesSolver

/// Renders the app's main screens in the states that matter, so the design can be reviewed
/// without a phone. Each screen is attached to the test result and, when SCREENSHOT_DIR is set,
/// written there as a PNG.
@MainActor
final class ScreenshotTests: XCTestCase {
  private var model: AppModel!
  private var testModeBefore = false

  override func setUp() async throws {
    try await super.setUp()
    model = AppModel()
    testModeBefore = model.testMode
    model.testMode = false  // so the screens show what a real listener sees
    await model.setSavePhotos(false)  // its default
    model.conversation.clear()
  }

  override func tearDown() async throws {
    model.showForScreenshots(registered: false)
    model.conversation.clear()
    model.testMode = testModeBefore
    model = nil
    try await super.tearDown()
  }

  func testScreens() async throws {
    model.showForScreenshots(registered: false, glassesAwake: false)
    try await shoot("1-solve-disconnected", ContentView(model: model))

    model.showForScreenshots(registered: false, registering: true)
    try await shoot("1b-solve-connecting", ContentView(model: model))

    model.showForScreenshots(registered: true, glassesAwake: false)
    try await shoot("2-solve-asleep", ContentView(model: model))

    model.showForScreenshots(registered: true)
    try await shoot("2c-solve-not-connected", ContentView(model: model))

    model.showForScreenshots(registered: true, starting: true)
    try await shoot("2d-solve-connecting-session", ContentView(model: model))

    model.showForScreenshots(registered: true, apiKey: false)
    try await shoot("2b-solve-no-api-key", ContentView(model: model))

    model.showForScreenshots(registered: true, session: true, phase: .thinking, workspace: Self.workspace(), photo: TestImages.image())
    try await shoot("3b-solve-solving", ContentView(model: model))

    model.showForScreenshots(registered: true, session: true, paused: true)
    try await shoot("3c-solve-paused", ContentView(model: model))

    model.showForScreenshots(registered: true, session: true, workspace: Self.workspace(), photo: TestImages.image())
    try await shoot("3-solve-connected-math", ContentView(model: model))

    model.showForScreenshots(
      registered: true, session: true, subject: .chemistry, photo: TestImages.image(),
      lastAnswer: "Question 7: B\nQuestion 8: D\nQuestion 9: A")
    try await shoot("4-solve-chemistry", ContentView(model: model))

    model.showForScreenshots(registered: true)
    try await shoot("5-history-empty", ContentView(model: model, tab: .history))

    model.conversation.add(
      prompt: "", photo: TestImages.jpeg(), answer: "Problem: 1\nThe answer: x = 5", error: nil,
      isTest: false, sessionID: nil, title: "Solve 3x + 7 = 22")
    model.conversation.add(
      prompt: "", photo: TestImages.jpeg(), answer: "Problem: 2\nThe answer: 12", error: nil,
      isTest: false, sessionID: nil, title: "Derivative of x squared at 6")
    try await shoot("6-history-populated", ContentView(model: model, tab: .history))

    try await shoot("7-settings", ContentView(model: model, tab: .settings))

    model.showForScreenshots(registered: true, workspace: Self.workspace(), photo: TestImages.image())
    try await shoot("8-written-answer", WrittenAnswerScreen(model: model), wait: 3)

    model.showForScreenshots(registered: true, session: true)
    try await shoot("9-session-controls", NavigationStack { SessionControlsView(model: model) })

    model.showForScreenshots(registered: false)
  }

  private static func workspace() -> MathWorkspace {
    let jpeg = TestImages.jpeg()
    var space = MathWorkspace(photo: jpeg, jpeg: jpeg)
    space.labels = ["1", "2"]
    space.problems["1"] = MathProblem(
      status: .ready, question: "Solve 3x + 7 = 22", answer: "x equals 5",
      work: [
        "Write: Subtract 7 from both sides || 3x + 7 - 7 = 22 - 7",
        "Write: Simplify || 3x = 15",
        "Write: Divide both sides by 3 || x = 5",
        "Mark: x = 5",
      ])
    space.problems["2"] = MathProblem(status: .preparing)
    return space
  }

  private static func webViews(in view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews(in:))
  }

  private func shoot(_ name: String, _ view: some View, wait seconds: Double = 1.5) async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    window.overrideUserInterfaceStyle = .dark
    window.rootViewController = UIHostingController(rootView: view)
    window.makeKeyAndVisible()
    try await Task.sleep(for: .seconds(seconds))

    var webShots: [(UIImage, CGRect)] = []
    for web in Self.webViews(in: window) {
      if let shot = try? await web.takeSnapshot(configuration: nil) {
        webShots.append((shot, web.convert(web.bounds, to: window)))
      }
    }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      // Web views draw blank this way; their own snapshots go on top.
      for (shot, frame) in webShots { shot.draw(in: frame) }
    }
    window.isHidden = true

    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], let png = image.pngData() {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
  }
}
