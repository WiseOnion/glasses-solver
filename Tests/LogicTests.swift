import Foundation
import UIKit
import XCTest

@testable import GlassesSolver

// MARK: - Speaking notation as words

@MainActor
final class SpeakableTests: XCTestCase {
  /// The same cases checked in Python while the rules were written.
  private let cases: [(String, String)] = [
    ("f'(x) = 2x·cos(x²)", "f prime of x equals 2x times cosine of (x squared)"),
    ("dy/dx = 3x^2 + 2", "d y d x equals 3x squared plus 2"),
    ("d/dx sin(x) = cos(x)", "the derivative with respect to x of sine of x equals cosine of x"),
    ("f''(x) = -sin x", "f double prime of x equals negative sine x"),
    ("sin²x + cos²x = 1", "sine squared of x plus cosine squared of x equals 1"),
    ("lim x→0 sin(x)/x = 1", "the limit as x approaches 0, of sine of x over x equals 1"),
    ("lim x→∞ 1/x = 0", "the limit as x approaches infinity, of 1 over x equals 0"),
    ("y = e^(2x+1)", "y equals e raised to the exponent 2x plus 1, end exponent"),
    ("y = x^4 - 3x^-2", "y equals x to the 4 minus 3x to the negative 2"),
    ("ln(x) has derivative 1/x", "natural log of x has derivative 1 over x"),
    ("arcsin(x) or sin^-1(x)", "inverse sine of x or inverse sine of x"),
    ("θ = π/6", "theta equals pi over 6"),
    ("tan x = sec x · sin x", "tangent x equals secant x times sine x"),
    ("It's the chain rule, so y' = 6x.", "It's the chain rule, so y prime equals 6x."),
    ("On 1/2/2026 it rose 5%.", "On 1/2/2026 it rose 5%."),
    ("Find the x-intercept at x = -3.", "Find the x-intercept at x equals negative 3."),
    ("The answer is x equals 5.", "The answer is x equals 5."),
  ]

  func testNotationIsSpokenAsWords() {
    for (input, expected) in cases {
      XCTAssertEqual(Speaker.speakable(input), expected, "input: \(input)")
    }
  }

  func testMarkdownAndLaTeXMarkersAreDropped() {
    XCTAssertEqual(Speaker.speakable("**Answer:** \\(x\\) = 5"), "Answer: x equals 5")
  }
}

// MARK: - Which camera failures get a fresh session

final class GlassesErrorTests: XCTestCase {
  func testFreshSessionRetryRules() {
    XCTAssertTrue(GlassesError.stream(.internalError).isFixedByFreshSession)
    XCTAssertTrue(GlassesError.cameraUnavailable.isFixedByFreshSession)
    XCTAssertTrue(GlassesError.captureRejected.isFixedByFreshSession)
    XCTAssertTrue(GlassesError.timedOut("taking the photo").isFixedByFreshSession)
    XCTAssertFalse(GlassesError.noGlasses.isFixedByFreshSession)
    XCTAssertFalse(GlassesError.sessionPaused.isFixedByFreshSession)
  }
}

// MARK: - Conversation history

@MainActor
final class ConversationStoreTests: XCTestCase {
  private var folder: URL!

  override func setUp() async throws {
    try await super.setUp()
    folder = FileManager.default.temporaryDirectory.appending(path: "conv-\(UUID().uuidString)")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder)
    try await super.tearDown()
  }

  private func add(_ store: ConversationStore, _ answer: String = "A", sessionID: UUID?, photo: Data? = nil) {
    store.add(prompt: "P", photo: photo, answer: answer, error: nil, isTest: true, sessionID: sessionID)
  }

  func testSessionGetsItsOwnChatAndIsArchived() throws {
    let store = ConversationStore(folder: folder)
    store.beginSession(prompt: "Solve it")
    let id = try XCTUnwrap(store.currentSessionID)
    add(store, sessionID: id)
    add(store, sessionID: id)
    XCTAssertEqual(store.entries(inSession: id).count, 2)
    store.endSession()
    XCTAssertNil(store.currentSessionID)
    XCTAssertEqual(store.pastSessions.map(\.id), [id])
    XCTAssertTrue(store.solveButtonDays.isEmpty)
  }

  func testAnswerArrivingAfterSessionEndsStaysInThatSession() throws {
    let store = ConversationStore(folder: folder)
    store.beginSession(prompt: "Solve it")
    let id = try XCTUnwrap(store.currentSessionID)
    store.endSession()  // stopped while Claude was still working
    add(store, "late answer", sessionID: id)
    XCTAssertEqual(store.entries(inSession: id).map(\.answer), ["late answer"])
    XCTAssertEqual(store.pastSessions.map(\.id), [id])
    XCTAssertTrue(store.solveButtonDays.isEmpty)
  }

  func testSolveButtonAnswersAreGroupedByDay() {
    let store = ConversationStore(folder: folder)
    add(store, sessionID: nil)
    add(store, sessionID: nil)
    XCTAssertEqual(store.solveButtonDays.count, 1)
    XCTAssertEqual(store.solveButtonEntries(on: store.solveButtonDays[0]).count, 2)
  }

  func testSavedAcrossRelaunchAndEmptySessionsPruned() throws {
    let store = ConversationStore(folder: folder)
    store.beginSession(prompt: "empty")
    store.endSession()
    store.beginSession(prompt: "used")
    let used = try XCTUnwrap(store.currentSessionID)
    add(store, sessionID: used)
    // Not ended: the app was closed mid-session.

    let reloaded = ConversationStore(folder: folder)
    XCTAssertEqual(reloaded.sessions.map(\.id), [used])
    XCTAssertNotNil(reloaded.sessions[0].ended)
    XCTAssertNil(reloaded.currentSessionID)
    XCTAssertEqual(reloaded.entries(inSession: used).count, 1)
  }

  func testOldSavedFormatStillLoads() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let old = [
      ConversationEntry(
        id: UUID(), date: .now, prompt: "P", answer: "old", error: nil, isTest: false, photoFile: nil)
    ]
    try JSONEncoder().encode(old).write(to: folder.appending(path: "history.json"))
    let store = ConversationStore(folder: folder)
    XCTAssertEqual(store.entries.map(\.answer), ["old"])
    XCTAssertEqual(store.solveButtonDays.count, 1)
  }

  func testPhotoIsSavedAndDeletedWithItsSession() throws {
    let store = ConversationStore(folder: folder)
    store.beginSession(prompt: "P")
    let id = try XCTUnwrap(store.currentSessionID)
    add(store, sessionID: id, photo: TestImages.jpeg())
    let url = try XCTUnwrap(store.photoURL(for: store.entries[0]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path()))
    store.endSession()
    store.deleteSession(id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path()))
    XCTAssertTrue(store.entries.isEmpty)
  }

  func testKeepsOnlyTheMostRecentAnswers() {
    let store = ConversationStore(folder: folder)
    for index in 0..<305 { add(store, "\(index)", sessionID: nil) }
    XCTAssertEqual(store.entries.count, 300)
    XCTAssertEqual(store.entries.first?.answer, "5")
  }
}

// MARK: - Claude request

/// Answers requests to api.anthropic.com with canned responses, in order.
final class StubAnthropic: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
  nonisolated(unsafe) static var requestCount = 0
  nonisolated(unsafe) static var lastHeaders: [String: String] = [:]

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host() == "api.anthropic.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requestCount += 1
    Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
    let next = Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
    let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(next.1.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class ClaudeClientTests: XCTestCase {
  private let answer = #"{"content":[{"type":"text","text":"The answer is 5."}],"stop_reason":"end_turn"}"#

  override func setUp() {
    super.setUp()
    StubAnthropic.responses = []
    StubAnthropic.requestCount = 0
    URLProtocol.registerClass(StubAnthropic.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(StubAnthropic.self)
    super.tearDown()
  }

  func testAnswerAndHeaders() async throws {
    StubAnthropic.responses = [(200, answer)]
    let text = try await ClaudeClient(apiKey: "sk-test").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(text, "The answer is 5.")
    XCTAssertEqual(StubAnthropic.lastHeaders["x-api-key"], "sk-test")
    XCTAssertEqual(StubAnthropic.lastHeaders["anthropic-version"], "2023-06-01")
  }

  func testOverloadIsRetriedOnce() async throws {
    StubAnthropic.responses = [(529, #"{"error":{"message":"Overloaded"}}"#), (200, answer)]
    let text = try await ClaudeClient(apiKey: "sk-test").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(text, "The answer is 5.")
    XCTAssertEqual(StubAnthropic.requestCount, 2)
  }

  func testBadKeyIsNotRetried() async {
    StubAnthropic.responses = [(401, #"{"error":{"message":"invalid x-api-key"}}"#), (200, answer)]
    do {
      _ = try await ClaudeClient(apiKey: "bad").solve(photo: TestImages.jpeg(), prompt: "Solve")
      XCTFail("expected an error")
    } catch ClaudeError.http(let status, _) {
      XCTAssertEqual(status, 401)
    } catch {
      XCTFail("unexpected error \(error)")
    }
    XCTAssertEqual(StubAnthropic.requestCount, 1)
  }

  func testRefusalAndEmptyAnswer() async {
    StubAnthropic.responses = [(200, #"{"content":[],"stop_reason":"refusal"}"#)]
    do {
      _ = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
      XCTFail("expected refusal")
    } catch ClaudeError.refused {
    } catch { XCTFail("unexpected error \(error)") }

    StubAnthropic.responses = [(200, #"{"content":[{"type":"thinking"}],"stop_reason":"end_turn"}"#)]
    do {
      _ = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
      XCTFail("expected empty answer")
    } catch ClaudeError.emptyAnswer {
    } catch { XCTFail("unexpected error \(error)") }
  }
}

// MARK: - Helpers

enum TestImages {
  /// A small image of a math problem, as JPEG.
  static func jpeg() -> Data {
    image().jpegData(compressionQuality: 0.9)!
  }

  static func image() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
      ("3x + 7 = 22" as NSString).draw(
        at: CGPoint(x: 60, y: 140),
        withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
    }
  }
}

/// Polls `condition` until it's true or the timeout passes.
@MainActor
func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    if Date() > deadline { return false }
    try? await Task.sleep(for: .milliseconds(100))
  }
  return true
}
