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

// MARK: - Diagnostics log

final class DiagnosticsLogTests: XCTestCase {
  /// Each line reaches the file at once, so it survives the app being ended right after.
  func testLinesAreWrittenToTheFileAtOnce() throws {
    let marker = "file check \(UUID().uuidString)"
    diag("test", marker)
    let saved = try String(contentsOf: DiagnosticsLog.fileURL, encoding: .utf8)
    XCTAssertTrue(saved.contains(marker))
  }
}

// MARK: - Timing each stage

final class SolveTimingTests: XCTestCase {
  func testEachStageIsTimedFromThePress() {
    var timing = SolveTiming(start: Date(timeIntervalSince1970: 0), pressed: true)
    timing.mark("photo taken", at: Date(timeIntervalSince1970: 2))
    timing.mark("Claude's first words arrived", at: Date(timeIntervalSince1970: 9))
    timing.mark("first words heard", at: Date(timeIntervalSince1970: 9.5))
    XCTAssertEqual(
      timing.summary,
      "press to first words 9.5 s: photo taken 2.0 s, Claude's first words arrived 7.0 s, first words heard 0.5 s")
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
  nonisolated(unsafe) static var lastBody: [String: Any]?

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host() == "api.anthropic.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requestCount += 1
    Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
    Self.lastBody = Self.body(of: request)
    let next = Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
    let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(next.1.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// The request's JSON body. URLSession hands it to the stub as a stream.
  private static func body(of request: URLRequest) -> [String: Any]? {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 65536)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

/// Server-sent events as the Messages API streams them: a thinking block, then one text
/// block per entry in `texts` (each sent in two pieces), then the stop reason.
func streamBody(_ texts: [String], stopReason: String? = "end_turn") -> String {
  func event(_ name: String, _ json: String) -> String { "event: \(name)\ndata: \(json)\n\n" }
  func quoted(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
  }
  var body = event("message_start", #"{"type":"message_start","message":{"content":[]}}"#)
  body += event("ping", #"{"type":"ping"}"#)
  body += event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
  body += event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#)
  body += event("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
  for (offset, text) in texts.enumerated() {
    let index = offset + 1
    body += event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
    let middle = text.index(text.startIndex, offsetBy: text.count / 2)
    for piece in [String(text[..<middle]), String(text[middle...])] {
      body += event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(quoted(piece))}}"#)
    }
    body += event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
  }
  if let stopReason {
    body += event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{"output_tokens":9}}"#)
    body += event("message_stop", #"{"type":"message_stop"}"#)
  }
  return body
}

/// Collects the pieces of text handed on while an answer streams.
@MainActor
final class Pieces {
  var all: [String] = []
}

final class ClaudeClientTests: XCTestCase {
  private let answer = streamBody(["The answer is 5."])

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
    let reply = try await ClaudeClient(apiKey: "sk-test").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(reply, .init(text: "The answer is 5.", stopReason: "end_turn"))
    XCTAssertTrue(reply.isComplete)
    XCTAssertEqual(StubAnthropic.lastHeaders["x-api-key"], "sk-test")
    XCTAssertEqual(StubAnthropic.lastHeaders["anthropic-version"], "2023-06-01")
  }

  func testTextIsHandedOnAsItArrives() async throws {
    StubAnthropic.responses = [(200, streamBody(["I can see problem 3.\nProblem: 3\n", "Done."]))]
    let pieces = await Pieces()
    let reply = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve") { piece in
      pieces.all.append(piece)
    }
    let all = await pieces.all
    XCTAssertGreaterThan(all.count, 2)
    // Separate text blocks are joined with a line break; thinking is skipped.
    XCTAssertEqual(all.joined(), "I can see problem 3.\nProblem: 3\n\nDone.")
    XCTAssertEqual(reply.text, all.joined())
  }

  func testAnAnswerThatRunsOutOfRoomIsContinued() async throws {
    // Out of room partway through line 2: the half-written line was never said, so it's
    // dropped and Claude, shown the complete lines, writes it again and finishes.
    StubAnthropic.responses = [
      (200, streamBody(["Problem: 4\nWrite: x\nWrite: y pr"], stopReason: "max_tokens")),
      (200, streamBody(["Write: y prime equals, 1\nDone."])),
    ]
    let restarts = await Pieces()
    let pieces = await Pieces()
    let reply = try await ClaudeClient(apiKey: "k").solve(
      photo: TestImages.jpeg(), prompt: "Solve", onText: { pieces.all.append($0) },
      onRestartLine: { restarts.all.append("restart") })
    XCTAssertEqual(reply, .init(text: "Problem: 4\nWrite: x\nWrite: y prime equals, 1\nDone.", stopReason: "end_turn"))
    XCTAssertEqual(StubAnthropic.requestCount, 2)
    let restartCount = await restarts.all.count
    XCTAssertEqual(restartCount, 1)
    // The second request shows what was written (complete lines only) and asks to go on.
    let messages = try XCTUnwrap(StubAnthropic.lastBody?["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
    let written = (messages[1]["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(written, "Problem: 4\nWrite: x")
    let ask = (messages[2]["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertTrue(ask?.contains("ran out of room") == true)
    XCTAssertEqual(StubAnthropic.lastBody?["max_tokens"] as? Int, ClaudeClient.maxTokens)
  }

  func testADroppedConnectionIsContinued() async throws {
    StubAnthropic.responses = [
      (200, streamBody(["Problem: 4\nWrite: x\n"], stopReason: nil)),
      (200, streamBody(["Done."])),
    ]
    let reply = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(reply, .init(text: "Problem: 4\nWrite: x\nDone.", stopReason: "end_turn"))
    let messages = try XCTUnwrap(StubAnthropic.lastBody?["messages"] as? [[String: Any]])
    let ask = (messages.last?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertTrue(ask?.contains("dropped connection") == true)
  }

  func testContinuingGivesUpAfterAFewTriesAndSaysWhy() async throws {
    // Always out of room: continued three times, then returned as cut off, so the listener
    // hears the notice.
    StubAnthropic.responses = Array(repeating: (status: 200, body: streamBody(["Write: x\n"], stopReason: "max_tokens")), count: 5)
    let reply = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(reply.stopReason, "max_tokens")
    XCTAssertEqual(StubAnthropic.requestCount, 1 + ClaudeClient.maxContinuations)
    // A continuation that fails returns what came, as a dropped connection.
    StubAnthropic.requestCount = 0
    StubAnthropic.responses = [
      (200, streamBody(["Problem: 4\nWrite: x\n"], stopReason: nil)), (400, #"{"error":{"message":"bad"}}"#),
    ]
    let dropped = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(dropped, .init(text: "Problem: 4\nWrite: x\n", stopReason: nil))
  }

  func testSystemPromptIsCachedAndFastModeIsAsked() async throws {
    ClaudeClient.fastModeRefused.set(false)
    StubAnthropic.responses = [(200, answer)]
    _ = try await ClaudeClient(apiKey: "k", fast: true).solve(photo: TestImages.jpeg(), prompt: "Solve")
    let body = try XCTUnwrap(StubAnthropic.lastBody)
    XCTAssertEqual(body["speed"] as? String, "fast")
    XCTAssertTrue(StubAnthropic.lastHeaders["anthropic-beta"]?.contains("fast-mode-2026-02-01") == true)
    let system = try XCTUnwrap(body["system"] as? [[String: Any]])
    XCTAssertEqual(system.first?["text"] as? String, ClaudeClient.system)
    let cache = try XCTUnwrap(system.first?["cache_control"] as? [String: String])
    XCTAssertEqual(cache, ["type": "ephemeral", "ttl": "1h"])
  }

  func testFastModeTurnedDownFallsBackToStandardSpeed() async throws {
    ClaudeClient.fastModeRefused.set(false)
    defer { ClaudeClient.fastModeRefused.set(false) }
    StubAnthropic.responses = [(400, #"{"error":{"message":"speed: fast mode is not available"}}"#), (200, answer)]
    let reply = try await ClaudeClient(apiKey: "k", fast: true).solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(reply.text, "The answer is 5.")
    XCTAssertEqual(StubAnthropic.requestCount, 2)
    XCTAssertNil(StubAnthropic.lastBody?["speed"])
    XCTAssertFalse(StubAnthropic.lastHeaders["anthropic-beta"]?.contains("fast-mode") == true)
    XCTAssertTrue(ClaudeClient.fastModeRefused.get(), "later requests shouldn't keep trying it")
  }

  func testPhotosAreSentSmallAndQuickly() throws {
    // A small JPEG from the glasses' stream goes as it is, with no re-encoding.
    let small = TestImages.jpeg()
    XCTAssertEqual(ClaudeClient.preparedJPEG(from: small), small)
    // A big still is scaled down to the long-edge cap.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let big = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4032, height: 3024))
    }.jpegData(compressionQuality: 0.9)!
    let prepared = try XCTUnwrap(ClaudeClient.preparedJPEG(from: big))
    let image = try XCTUnwrap(UIImage(data: prepared))
    XCTAssertEqual(max(image.size.width, image.size.height), 1568, accuracy: 1)
    XCTAssertEqual(min(image.size.width, image.size.height), 1176, accuracy: 1)
  }

  func testCompleteLines() {
    XCTAssertEqual(ClaudeClient.completeLines("a\nb\nc"), "a\nb\n")
    XCTAssertEqual(ClaudeClient.completeLines("a\n"), "a\n")
    XCTAssertEqual(ClaudeClient.completeLines("abc"), "")
    XCTAssertTrue(ClaudeClient.continuation(of: " \n", reason: nil).isEmpty)
  }

  func testFollowUpPhotoIncludesTheEarlierAnswer() throws {
    let jpeg = try XCTUnwrap(ClaudeClient.preparedJPEG(from: TestImages.jpeg()))
    // A first photo: just the photo and the prompt.
    let first = ClaudeClient.body(jpeg: jpeg, prompt: "Solve", previousAnswer: nil)
    let firstMessages = try XCTUnwrap(first["messages"] as? [[String: Any]])
    XCTAssertEqual(firstMessages.map { $0["role"] as? String }, ["user"])
    // A follow-up: the earlier prompt (no photo), the earlier answer, then the new photo.
    let followUp = ClaudeClient.body(jpeg: jpeg, prompt: "Solve", previousAnswer: "Problem: 3\nWrite: x")
    let messages = try XCTUnwrap(followUp["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
    let types = messages.map { ($0["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String } ?? [] }
    XCTAssertEqual(types, [["text"], ["text"], ["image", "text"]])
    let answer = (messages[1]["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(answer, "Problem: 3\nWrite: x")
    XCTAssertEqual(followUp["stream"] as? Bool, true)
  }

  func testAPhotoTakenMidAnswerSaysWhereItStopped() throws {
    let jpeg = try XCTUnwrap(ClaudeClient.preparedJPEG(from: TestImages.jpeg()))
    let note = AppModel.describeStop(.init(problem: "3", line: 4, lineFinished: false))
    XCTAssertEqual(
      note,
      "Your dictation was cut short when I took this photo: I'd heard problem 3 up to partway through line 4, "
        + "and nothing after that.")
    XCTAssertTrue(
      AppModel.describeStop(.init(problem: "5, part A", line: 2, lineFinished: true))
        .contains("problem 5, part A up to the end of line 2"))
    XCTAssertTrue(AppModel.describeStop(.init(problem: "2", line: 0, lineFinished: false)).contains("none of its lines"))
    let body = ClaudeClient.body(jpeg: jpeg, prompt: "Solve", previousAnswer: "Problem: 3\nWrite: x", stoppedAt: note)
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let text = (messages[2]["content"] as? [[String: Any]])?.last?["text"] as? String
    XCTAssertEqual(text, note + " " + ClaudeClient.followUpPrompt)
  }

  func testOverloadIsRetriedOnce() async throws {
    StubAnthropic.responses = [(529, #"{"error":{"message":"Overloaded"}}"#), (200, answer)]
    let reply = try await ClaudeClient(apiKey: "sk-test").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(reply.text, "The answer is 5.")
    XCTAssertEqual(StubAnthropic.requestCount, 2)
  }

  func testOverloadInsideTheStreamIsRetriedBeforeAnyText() async throws {
    let overloaded = #"event: error"# + "\n"
      + #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"# + "\n\n"
    StubAnthropic.responses = [(200, overloaded), (200, answer)]
    let reply = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
    XCTAssertEqual(reply.text, "The answer is 5.")
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
    StubAnthropic.responses = [(200, streamBody([], stopReason: "refusal"))]
    do {
      _ = try await ClaudeClient(apiKey: "k").solve(photo: TestImages.jpeg(), prompt: "Solve")
      XCTFail("expected refusal")
    } catch ClaudeError.refused {
    } catch { XCTFail("unexpected error \(error)") }

    StubAnthropic.responses = [(200, streamBody([]))]
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
