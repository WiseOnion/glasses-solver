import Foundation
import MWDATInputs
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

  func testChemistryUsesItsOwnPromptAndMoreThought() throws {
    let jpeg = try XCTUnwrap(ClaudeClient.preparedJPEG(from: TestImages.jpeg()))
    let math = ClaudeClient.body(jpeg: jpeg, prompt: "Solve", previousAnswer: nil)
    XCTAssertEqual((math["output_config"] as? [String: Any])?["effort"] as? String, "medium")
    let body = ClaudeClient.body(jpeg: jpeg, prompt: "Solve", previousAnswer: nil, subject: .chemistry)
    let system = try XCTUnwrap(body["system"] as? [[String: Any]])
    XCTAssertEqual(system.first?["text"] as? String, ClaudeClient.chemistrySystem)
    XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "high")
  }

  /// The warm-up must match a photo's cached prefix (prompt, effort, speed) or the photo
  /// can't read it, and `max_tokens` 0 is refused with streaming.
  func testWarmUpMatchesAPhotosCachedPrefix() throws {
    let jpeg = try XCTUnwrap(ClaudeClient.preparedJPEG(from: TestImages.jpeg()))
    let photo = ClaudeClient.body(
      messages: ClaudeClient.messages(jpeg: jpeg, prompt: "Solve", previousAnswer: nil, stoppedAt: nil, subject: .chemistry),
      fast: true, subject: .chemistry)
    let warm = ClaudeClient.warmUpBody(subject: .chemistry, fast: true)
    XCTAssertEqual(warm["max_tokens"] as? Int, 0)
    XCTAssertEqual(warm["stream"] as? Bool, false)
    XCTAssertNil(warm["fallbacks"])
    for key in ["model", "speed"] { XCTAssertEqual(warm[key] as? String, photo[key] as? String) }
    XCTAssertEqual(
      (warm["output_config"] as? [String: Any])?["effort"] as? String,
      (photo["output_config"] as? [String: Any])?["effort"] as? String)
    let warmSystem = try XCTUnwrap(warm["system"] as? [[String: Any]])
    XCTAssertEqual(warmSystem.first?["text"] as? String, ClaudeClient.chemistrySystem)
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

  /// A chemistry photo can show the answer sheet or handwritten work on a worked problem, so
  /// the follow-up asks about both.
  func testChemistryFollowUp() throws {
    let jpeg = try XCTUnwrap(ClaudeClient.preparedJPEG(from: TestImages.jpeg()))
    let body = ClaudeClient.body(
      jpeg: jpeg, prompt: "Answer", previousAnswer: "Problem: 9\nAnswer: A, as in apple.", subject: .chemistry)
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let text = (messages[2]["content"] as? [[String: Any]])?.last?["text"] as? String
    XCTAssertEqual(text, ClaudeClient.Subject.chemistry.followUpPrompt)
    XCTAssertTrue(text?.contains("answer sheet") == true)
    XCTAssertTrue(text?.contains("my own work") == true)
  }

  /// Chemistry keeps its dictated pen lines for worked problems; math's work goes to the
  /// phone under its own rules, so the two never mix.
  func testChemistryPromptHasWorkedProblems() {
    XCTAssertTrue(ClaudeClient.chemistrySystem.contains(ClaudeClient.penLineRules))
    XCTAssertTrue(ClaudeClient.system.contains(ClaudeClient.mathWorkRules))
    XCTAssertFalse(ClaudeClient.system.contains(ClaudeClient.penLineRules))
    XCTAssertFalse(ClaudeClient.chemistrySystem.contains(ClaudeClient.mathWorkRules))
    XCTAssertTrue(ClaudeClient.chemistrySystem.contains("DIMENSIONAL ANALYSIS"))
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

// MARK: - Checking finished work

final class CheckTests: XCTestCase {
  /// Each subject's system prompt has its own check rules, so a check request reads the same
  /// cached prompt as a solve.
  func testBothSystemPromptsHaveTheCheckRules() {
    XCTAssertTrue(ClaudeClient.system.contains(ClaudeClient.mathCheckRules))
    XCTAssertTrue(ClaudeClient.chemistrySystem.contains(ClaudeClient.checkRules))
  }

  /// A check follow-up sends the check request with the new photo, not "continue".
  func testCheckFollowUpSendsItsOwnRequest() throws {
    let jpeg = try XCTUnwrap(ClaudeClient.preparedJPEG(from: TestImages.jpeg()))
    let check = ClaudeClient.PhotoAction.checkPrompt
    let body = ClaudeClient.body(jpeg: jpeg, prompt: check, previousAnswer: "Problem: 3", action: .check)
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let text = (messages[2]["content"] as? [[String: Any]])?.last?["text"] as? String
    XCTAssertEqual(text, check)
  }
}

// MARK: - Math: answer first

@MainActor
final class MathReplyTests: XCTestCase {
  func testAReplyIsReadLineByLine() {
    let reply = MathReply.parse(AppModel.simulatedMathReply(label: nil))
    XCTAssertEqual(reply.labels, ["1", "2"])
    XCTAssertEqual(reply.label, "1")
    XCTAssertEqual(reply.answer, "x equals negative 1 half, or x equals negative 3.")
    XCTAssertFalse(reply.explanation.isEmpty)
    XCTAssertFalse(reply.ownWork)
    XCTAssertEqual(reply.work.count, 4)
    XCTAssertTrue(reply.work.allSatisfy { $0.hasPrefix("Write:") || $0.hasPrefix("Mark:") })
  }

  /// The answer is said the moment its line is complete, and not a moment before.
  func testAnAnswerCountsOnlyOnceItsLineIsComplete() {
    let arriving = "Problems: 4, 5 and 6\nProblem: 4\nQuestion: a limit\nAnswer: x equ"
    let partial = MathReply.parse(ClaudeClient.completeLines(arriving))
    XCTAssertEqual(partial.labels, ["4", "5", "6"])
    XCTAssertEqual(partial.label, "4")
    XCTAssertEqual(partial.answer, "")
    let complete = MathReply.parse(arriving + "als 4.\n")
    XCTAssertEqual(complete.answer, "x equals 4.")
  }

  /// An answer written over two lines is kept whole, and isn't used (or said) until the next
  /// tag starts: `answerIfComplete` is what the app stores and speaks.
  func testAMultiLineAnswerIsWaitedForAndKeptWhole() {
    let head = "Problems: 2\nProblem: 2\nQuestion: where f increases and decreases\n"
    let first = "Answer: f is increasing on negative infinity to negative 1, and 3 to infinity,\n"
    let second = "and decreasing on negative 1 to 3.\n"
    let whole =
      "f is increasing on negative infinity to negative 1, and 3 to infinity, and decreasing on negative 1 to 3."
    // As it streams: the first line alone, then both lines, then the start of the next tag.
    XCTAssertNil(MathReply.parse(head + first, complete: false).answerIfComplete)
    XCTAssertNil(MathReply.parse(head + first + second, complete: false).answerIfComplete)
    XCTAssertNil(MathReply.parse(head + first + second + "Expl", complete: false).answerIfComplete)
    XCTAssertEqual(MathReply.parse(head + first + second + "Explain: The", complete: false).answerIfComplete, whole)
    // The explanation isn't complete yet either, since its line is still arriving.
    XCTAssertNil(MathReply.parse(head + first + second + "Explain: The", complete: false).explanationIfComplete)
    // The whole reply, and a reply that ends right after the answer.
    let reply = MathReply.parse(head + first + second + "Explain: Two\nlines.\nOwn work: no\nWork:\nWrite: x || x")
    XCTAssertEqual(reply.answerIfComplete, whole)
    XCTAssertEqual(reply.explanationIfComplete, "Two lines.")
    XCTAssertEqual(reply.work, ["Write: x || x"])
    XCTAssertEqual(MathReply.parse(head + first + second).answerIfComplete, whole)
    // A one-line answer is complete as soon as the next tag starts.
    XCTAssertEqual(MathReply.parse(head + "Answer: x equals 4.\nExplain:", complete: false).answerIfComplete, "x equals 4.")
  }

  /// A reply that can't be used says why, and each kind is told apart in the log and history.
  func testUnusableRepliesAreToldApart() {
    // A valid answer, but no Problem line: a format problem, not an unreadable photo.
    let noProblemLine = MathReply.parse("Problems: 4\nQuestion: a limit\nAnswer: x equals 4.\nExplain: e\nOwn work: no\nWork:")
    XCTAssertEqual(noProblemLine.failure(asked: nil), .missingProblemLine)
    XCTAssertNil(noProblemLine.failure(asked: "4"), "a named problem's reply doesn't need the Problem line")
    // Malformed: text with none of the expected tags.
    let malformed = MathReply.parse("Sure! The answer to problem 4 is x = 4.")
    XCTAssertEqual(malformed.failure(asked: nil), .unparseable)
    XCTAssertTrue(malformed.tagsSeen.isEmpty)
    // Unreadable: Claude said it couldn't make the photo out.
    let unreadable = MathReply.parse("Problems:\nUnclear: the exponent in problem 4 is cut off.")
    XCTAssertEqual(unreadable.failure(asked: nil), .unreadable)
    // No usable answer: the right tags, but no answer.
    let noAnswer = MathReply.parse("Problems: 4\nProblem: 4\nQuestion: a limit\nOwn work: no\nWork:")
    XCTAssertEqual(noAnswer.failure(asked: nil), .noAnswer)
    // A usable reply.
    XCTAssertNil(MathReply.parse(AppModel.simulatedMathReply(label: nil)).failure(asked: nil))

    let kinds: [MathReply.Failure] = [.missingProblemLine, .unparseable, .unreadable, .noAnswer]
    XCTAssertEqual(Set(kinds.map(\.rawValue)).count, 4)
    // Only an unreadable photo is spoken as one.
    XCTAssertTrue(AppModel.spokenFailure(.unreadable, unclear: "it's cut off.").hasPrefix("Couldn't read that"))
    for kind in [MathReply.Failure.missingProblemLine, .unparseable, .noAnswer] {
      XCTAssertFalse(AppModel.spokenFailure(kind, unclear: nil).contains("read"), "\(kind) blames the photo")
    }
    // Request failures are named apart from replies that couldn't be used.
    XCTAssertEqual(AppModel.requestFailureKind(ClaudeError.emptyAnswer), "reply-empty")
    XCTAssertEqual(AppModel.requestFailureKind(ClaudeError.refused), "claude-refused")
    XCTAssertEqual(AppModel.requestFailureKind(URLError(.timedOut)), "claude-request-failed")
  }

  func testUnclearPhotoAndVerdicts() {
    XCTAssertEqual(MathReply.parse("Problems:\nUnclear: the exponent is cut off.").unclear, "the exponent is cut off.")
    XCTAssertEqual(
      MathReply.parse("Verdict: Incorrect. The answer is x equals 5.").verdict, "Incorrect. The answer is x equals 5.")
    XCTAssertTrue(MathReply.parse("Own work: yes").ownWork)
  }

  /// The work goes to the written answer page, as the page already reads it.
  func testTheWorkShowsOnTheWrittenPage() {
    let reply = MathReply.parse(AppModel.simulatedMathReply(label: nil))
    var problem = MathProblem()
    problem.answer = reply.answer
    problem.work = reply.work
    let written = WrittenAnswer.parse(problem.written(label: "1"))
    XCTAssertFalse(written.isEmpty)
    XCTAssertEqual(written.problems.first?.label, "1")
    XCTAssertEqual(written.problems.first?.lines.count, 3)
    XCTAssertEqual(written.problems.first?.lines.last?.boxed, true)
  }

  /// The photo is cached, so the next problem and Check don't pay to read it again.
  func testTheMathPhotoIsCached() throws {
    let messages = ClaudeClient.photoMessages(jpeg: Data([1, 2, 3]), ask: ClaudeClient.solveAsk)
    let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
    XCTAssertEqual(content.first?["type"] as? String, "image")
    XCTAssertEqual(content.first?["cache_control"] as? [String: String], ["type": "ephemeral"])
    XCTAssertEqual(content.last?["text"] as? String, ClaudeClient.solveAsk)
  }

  /// Check's re-solve never sees the first answer.
  func testTheResolveDoesNotShowTheFirstAnswer() {
    XCTAssertFalse(ClaudeClient.resolveAsk("4").contains("Answer"))
    XCTAssertTrue(ClaudeClient.compareAsk(label: "4", question: "q", first: "A1", second: "A2").contains("A1"))
  }

  /// The Test 3 rules and the course notes are in the math prompt.
  func testTheMathPromptHasTest3AndTheCourseNotes() {
    XCTAssertTrue(ClaudeClient.system.contains("THIS COURSE: MATH 131, TEST 3"))
    XCTAssertFalse(ClaudeClient.courseNotes.isEmpty, "Courses/MATH131.md isn't in the app")
    XCTAssertTrue(ClaudeClient.system.contains(ClaudeClient.courseNotes))
  }

  /// The direct-answering rule is in the system prompt a real math request sends, at the top
  /// of the reply format, and only in math's.
  func testTheMathPromptSaysToAnswerDirectly() throws {
    let rule =
      "Solve what's visible. Never ask the user a question. No introductions, disclaimers, or commentary. "
      + "Use `Unclear:` only when something physically unreadable could change the answer."
    let body = ClaudeClient.body(
      messages: ClaudeClient.MathRequest.photo(jpeg: Data([1]), ask: ClaudeClient.solveAsk).messages, subject: .math)
    let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first?["text"] as? String)
    XCTAssertTrue(system.contains("THE SHAPE OF A REPLY\n" + rule + "\nWork the problem out completely"))
    XCTAssertFalse(ClaudeClient.chemistrySystem.contains(rule))
  }

  /// Chemistry's swipe replays a question from the last answer, with no new request.
  func testAChemistryAnswerSplitsIntoQuestions() {
    let answer = """
      I can see questions 7 and 13.
      Problem: 7
      Answer: B, as in boy. Krypton core.
      Problem: 13
      Answer: D, as in dog.
      Done.
      """
    let questions = AppModel.questions(in: answer)
    XCTAssertEqual(questions.map(\.label), ["7", "13"])
    XCTAssertEqual(questions[1].text, "Problem: 13\nAnswer: D, as in dog.")
  }

  /// Every gesture an app can receive is passed on as its own kind.
  func testGesturesFromTheGlasses() {
    XCTAssertEqual(ShutterButton.gesture(for: .capture(.shortPress, source: .captureButton, timestampMs: 1)), .capturePress)
    XCTAssertEqual(
      ShutterButton.gesture(for: .capture(.doublePress, source: .captureButton, timestampMs: 1)), .captureDoublePress)
    XCTAssertEqual(ShutterButton.gesture(for: .capture(.hold, source: .captureButton, timestampMs: 1)), .captureHold)
    XCTAssertEqual(ShutterButton.gesture(for: .select(source: .captouch, timestampMs: 1)), .touchpadDoubleTap)
    XCTAssertEqual(ShutterButton.gesture(for: .nav(direction: .left, source: .captouch, timestampMs: 1)), .swipe(.left))
    XCTAssertNil(ShutterButton.gesture(for: .button(.action, source: .actionButton, timestampMs: 1)))
  }
}

// MARK: - Audit: math replies, as streamed and as finished

@MainActor
final class MathReplyAuditTests: XCTestCase {
  private let head = "Problems: 4\nProblem: 4\nQuestion: a limit\n"

  /// However an answer is followed, it's complete only once the next tag has started (or a
  /// reply Claude ended itself is over), never after its first line alone.
  func testEveryWayAnAnswerEnds() {
    let followers = ["Explain: why", "Own work: no", "Work:", "Write: x || x", "Problem: 5"]
    for answer in ["Answer: x equals 4.\n", "Answer: f is increasing on 1 to 2,\nand decreasing on 2 to 3.\n"] {
      let whole = answer.dropFirst("Answer: ".count).replacingOccurrences(of: ",\n", with: ", ")
        .trimmingCharacters(in: .newlines)
      XCTAssertNil(MathReply.parse(head + answer, complete: false).answerIfComplete, "said before it was over")
      for follower in followers {
        let tagOnly = String(follower.prefix(upTo: follower.firstIndex(of: ":")!)) + ":"
        XCTAssertEqual(
          MathReply.parse(head + answer + tagOnly, complete: false).answerIfComplete, whole, "followed by \(follower)")
        XCTAssertEqual(MathReply.parse(head + answer + follower + "\n").answerIfComplete, whole)
      }
      // The reply ends right after the answer.
      XCTAssertEqual(MathReply.parse(head + answer).answerIfComplete, whole)
      XCTAssertEqual(AppModel.finalReply(.init(text: head + answer, stopReason: "end_turn")).answerIfComplete, whole)
    }
  }

  /// Empty, malformed and partial replies never give an answer to say.
  func testEmptyMalformedAndPartialReplies() {
    XCTAssertEqual(MathReply.parse("").failure(asked: nil), .unparseable)
    XCTAssertEqual(MathReply.parse("I'm not sure what this is.").failure(asked: nil), .unparseable)
    XCTAssertNil(MathReply.parse(head + "Answer: x equ", complete: false).answerIfComplete)
    XCTAssertNil(MathReply.parse(head + "Answer:", complete: false).answerIfComplete)
    XCTAssertNil(MathReply.parse(head + "Answer:\nExplain: e").answerIfComplete, "an empty answer isn't an answer")
    XCTAssertEqual(MathReply.parse(head + "Answer:\nExplain: e").failure(asked: nil), .noAnswer)
  }

  /// A reply that was cut off (out of room, refused, or dropped after its continuations) can
  /// end partway through a line, so it's never read as finished.
  func testACutOffReplyIsNeverTakenAsFinished() {
    for stopReason in ["max_tokens", "refusal", nil] as [String?] {
      let midLine = ClaudeClient.Answer(text: head + "Answer: x equ", stopReason: stopReason)
      XCTAssertNil(AppModel.finalReply(midLine).answerIfComplete, "\(stopReason ?? "dropped"): half a line")
      let midAnswer = ClaudeClient.Answer(text: head + "Answer: f is increasing on 1 to 2,\n", stopReason: stopReason)
      XCTAssertNil(AppModel.finalReply(midAnswer).answerIfComplete, "\(stopReason ?? "dropped"): half an answer")
      // An answer finished before the cut is kept.
      let after = ClaudeClient.Answer(text: head + "Answer: x equals 4.\nExplain: Bec", stopReason: stopReason)
      XCTAssertEqual(AppModel.finalReply(after).answerIfComplete, "x equals 4.")
      XCTAssertNil(AppModel.finalReply(after).explanationIfComplete)
      // A check cut off mid-verdict isn't said as one.
      let verdict = ClaudeClient.Answer(text: "Verdict: Incorrect. The answer is x equ", stopReason: stopReason)
      XCTAssertEqual(AppModel.verdict(in: verdict, request: "4"), "Unclear. The check didn't give a result.")
    }
    let finished = ClaudeClient.Answer(text: "Verdict: Correct. x equals 4.", stopReason: "end_turn")
    XCTAssertEqual(AppModel.verdict(in: finished, request: "4"), "Correct. x equals 4.")
  }

  /// The example reply in Claude's math instructions, word for word, parses as intended.
  func testTheInstructionsExampleReplyParses() throws {
    let system = ClaudeClient.system
    let start = try XCTUnwrap(system.range(of: "AN EXAMPLE REPLY, word for word\n"))
    let rest = system[start.upperBound...]
    let example = String(rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)])
    let reply = AppModel.finalReply(.init(text: example, stopReason: "end_turn"))
    XCTAssertNil(reply.failure(asked: nil))
    XCTAssertEqual(reply.labels, ["2", "3"])
    XCTAssertEqual(reply.label, "2")
    XCTAssertEqual(
      reply.answerIfComplete,
      "f is increasing on negative infinity to negative 1, and 3 to infinity, and decreasing on negative 1 to 3. "
        + "Local max of 6 at x equals negative 1, local min of negative 26 at x equals 3.")
    XCTAssertTrue(reply.explanationIfComplete?.hasPrefix("The derivative factors") == true)
    XCTAssertFalse(reply.ownWork)
    XCTAssertEqual(reply.work.count, 8)
    var problem = MathProblem()
    problem.answer = reply.answer
    problem.work = reply.work
    let written = WrittenAnswer.parse(problem.written(label: "2"))
    XCTAssertEqual(written.problems.first?.lines.count, 6)
    XCTAssertEqual(written.problems.first?.lines.filter(\.boxed).map(\.number), [5, 6])
  }

  /// The other reply shapes the instructions ask for: a named problem, a re-solve, every kind
  /// of verdict, an explanation alone, an unreadable photo, and lettered problems.
  func testEveryOtherReplyShapeTheInstructionsAskFor() {
    let named = MathReply.parse("Problems: 4, 5\nProblem: 5\nQuestion: q\nAnswer: c equals 2.\nExplain: e\nOwn work: no\nWork:\nWrite: c = 2 || c = 2")
    XCTAssertNil(named.failure(asked: "5"))
    XCTAssertEqual(named.answerIfComplete, "c equals 2.")
    let resolve = MathReply.parse("Problem: 4\nAnswer: x equals 4.\nWork:\nWrite: x = 4 || x = 4")
    XCTAssertEqual(resolve.answerIfComplete, "x equals 4.")
    XCTAssertEqual(resolve.work, ["Write: x = 4 || x = 4"])
    for verdict in [
      "Correct. x equals 4.", "Incorrect. The answer is x equals 5, because the 7 wasn't distributed.",
      "Unclear. The exponent can't be read.", "Correct. Your work is right.",
      "Incorrect. Line 3 has a mistake: the 7 wasn't distributed to the second term.",
    ] {
      XCTAssertEqual(
        AppModel.verdict(in: .init(text: "Verdict: \(verdict)", stopReason: "end_turn"), request: "4"), verdict)
    }
    XCTAssertEqual(MathReply.parse("Explain: First this. Then that.").explanationIfComplete, "First this. Then that.")
    XCTAssertEqual(MathReply.parse("Problems:\nUnclear: problem 4 is cut off.").failure(asked: nil), .unreadable)
    XCTAssertEqual(MathReply.parse("Problems: 5a, 5b\nProblem: 5a\nAnswer: 3.").labels, ["5a", "5b"])
    XCTAssertEqual(MathReply.parse("Problems: 4, 5 and 6").labels, ["4", "5", "6"])
    // A Write line whose LaTeX has its own colons stays one pen line.
    XCTAssertEqual(
      MathReply.parse("Work:\nWrite: f of x || f: [0, 2] \\to \\mathbb{R}").work, ["Write: f of x || f: [0, 2] \\to \\mathbb{R}"])
  }

  /// Own work, the answer, the explanation and the work all parse together.
  func testAnOwnWorkReplyParses() {
    let reply = MathReply.parse(
      head + "Answer: x equals 4.\nExplain: Subtract 7, then divide by 3.\nOwn work: yes\nWork:\n"
        + "Write: 3 x equals 12 || 3x = 12\nWrite: x equals 4 || x = 4\nMark: Draw a box around line 2.")
    XCTAssertTrue(reply.ownWork)
    XCTAssertEqual(reply.answerIfComplete, "x equals 4.")
    XCTAssertEqual(reply.explanationIfComplete, "Subtract 7, then divide by 3.")
    XCTAssertEqual(reply.work.count, 3)
    XCTAssertFalse(MathReply.parse("Own work: no").ownWork)
  }

  /// What each math request actually sends: the instructions with the course notes, the
  /// photo, and the problem asked for. The re-solve gets nothing of the first answer.
  func testWhatEachMathRequestSends() throws {
    let jpeg = Data([0xFF, 0xD8, 1, 2, 3])
    func parts(_ request: ClaudeClient.MathRequest) throws -> (system: String, content: [[String: Any]]) {
      let body = ClaudeClient.body(messages: request.messages, subject: .math)
      let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first?["text"] as? String)
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 1, "only one message: no earlier turns")
      return (system, try XCTUnwrap(messages.first?["content"] as? [[String: Any]]))
    }
    let second = try parts(.photo(jpeg: jpeg, ask: ClaudeClient.problemAsk("2")))
    XCTAssertTrue(second.system.contains("THIS COURSE: MATH 131, TEST 3"))
    XCTAssertTrue(second.system.contains(ClaudeClient.courseNotes))
    XCTAssertFalse(ClaudeClient.courseNotes.isEmpty)
    let image = try XCTUnwrap(second.content.first?["source"] as? [String: String])
    XCTAssertEqual(image["data"], jpeg.base64EncodedString(), "the same photo bytes")
    XCTAssertEqual(second.content.last?["text"] as? String, "Solve problem 2 in this photo.")

    let resolve = try parts(.photo(jpeg: jpeg, ask: ClaudeClient.resolveAsk("2")))
    XCTAssertEqual(resolve.content.count, 2, "the photo and the request, nothing else")
    XCTAssertEqual(resolve.content.last?["text"] as? String, "Re-solve problem 2 in this photo.")
    // The first answer, its work, explanation and check exist only in the later comparison.
    var first = MathProblem()
    first.answer = "x equals 4."
    first.work = ["Write: x = 4 || x = 4"]
    first.explanation = "Because."
    first.check = "Correct."
    let compare = ClaudeClient.compareAsk(label: "2", question: "q", first: first.solution, second: "Answer: x equals 5.")
    XCTAssertTrue(compare.contains("x equals 4.") && compare.contains("Write: x = 4"))
    XCTAssertFalse(compare.contains("Because.") || compare.contains("Correct."), "no explanation or earlier check")
  }
}
