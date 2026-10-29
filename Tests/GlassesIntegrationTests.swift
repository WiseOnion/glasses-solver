import AVFoundation
import Foundation
import MWDATCore
import MWDATMockDevice
import UIKit
import XCTest

@testable import GlassesSolver

/// End-to-end tests against Meta's simulated glasses (MockDeviceKit): sessions, the camera,
/// the capture button and touchpad, and the hands-free flow in Test mode. Real glasses can
/// behave differently (SDK 1.0.0's second-stream failure is hardware-side), but these check
/// the app's own logic around them.
@MainActor
final class GlassesIntegrationTests: XCTestCase {
  private var glasses: (any MockGlasses)?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()  // the test host app has usually configured it already
    MockDeviceKit.shared.enable()
    let mock = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mock.powerOn()
    mock.unfold()
    mock.don()
    mock.services.camera.setCapturedImage(fileURL: try TestMedia.imageFile())
    mock.services.camera.setCameraFeed(fileURL: try await TestMedia.videoFile())
    glasses = mock
    try await Task.sleep(for: .seconds(1))  // let the SDK see the device
  }

  override func tearDown() async throws {
    if testRun?.hasSucceeded == false {
      print("----- Diagnostics log for \(name) -----\n\(DiagnosticsLog.shared.text)\n-----")
    }
    DiagnosticsLog.shared.clear()
    await MockDeviceKit.shared.disable()
    glasses = nil
    try await super.tearDown()
  }

  private func makeCamera() async -> (GlassesCamera, AutoDeviceSelector) {
    let selector = AutoDeviceSelector(wearables: Wearables.shared)
    let found = await waitUntil(10) { selector.activeDevice != nil }
    XCTAssertTrue(found, "the simulated glasses never became the active device")
    return (GlassesCamera(wearables: Wearables.shared, selector: selector), selector)
  }

  /// The fix for photos after the first failing: a fresh session per photo.
  func testTwoPhotosWithAFreshSessionBetween() async throws {
    let (camera, _) = await makeCamera()
    let first = try await camera.capturePhoto(highResolution: false)
    XCTAssertNotNil(UIImage(data: first), "first photo isn't an image")
    _ = try await camera.refreshSession()
    let second = try await camera.capturePhoto(highResolution: false)
    XCTAssertNotNil(UIImage(data: second), "second photo isn't an image")
    camera.endSession()
  }

  /// Two session starts at once share one session instead of opening two.
  func testConcurrentSessionStartsShareOneSession() async throws {
    let (camera, _) = await makeCamera()
    async let a = camera.startedSession()
    async let b = camera.startedSession()
    let (first, second) = try await (a, b)
    XCTAssertTrue(first === second)
    camera.endSession()
  }

  /// Every gesture reaches the app as its own kind: capture short press, double press and
  /// hold, touchpad double-tap and swipes.
  func testEveryGestureReachesTheApp() async throws {
    let (camera, _) = await makeCamera()
    let session = try await camera.startedSession()
    let shutter = ShutterButton()
    let events = EventCounter()
    shutter.attach(
      to: session,
      onGesture: { gesture, _ in events.gestures.append(gesture) },
      onStatus: { _ in })
    let active = await waitUntil(15) { shutter.status == .active }
    XCTAssertTrue(active, "button events never became active (status \(shutter.status))")

    let input = try XCTUnwrap(glasses).services.input
    input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
    input.capture(pressType: MWDATMockDevice.CapturePressType.doublePress)
    input.capture(pressType: MWDATMockDevice.CapturePressType.hold)
    input.select(source: MWDATMockDevice.InputSource.captouch)
    input.navRight(source: MWDATMockDevice.InputSource.captouch)
    let arrived = await waitUntil(5) { events.gestures.count == 5 }
    XCTAssertTrue(arrived, "gestures that arrived: \(events.gestures)")
    XCTAssertEqual(
      events.gestures, [.capturePress, .captureDoublePress, .captureHold, .touchpadDoubleTap, .swipe(.right)])

    shutter.detach(from: session)
    camera.endSession()
  }

  /// The whole hands-free flow in Test mode (no Claude): two presses, two answers, both in
  /// the session's own chat, which is archived when the session stops.
  func testHandsFreeSessionInTestMode() async throws {
    let model = AppModel()
    let wasTestMode = model.testMode
    let wasSubject = model.subject
    model.testMode = true
    model.subject = .math
    defer {
      model.testMode = wasTestMode
      model.subject = wasSubject
    }

    let ready = await waitUntil(10) { model.isRegistered && model.hasActiveDevice }
    XCTAssertTrue(ready, "registered \(model.isRegistered), glasses \(model.hasActiveDevice)")
    await model.startSession(prompt: "Test prompt")
    XCTAssertTrue(model.sessionActive, "session didn't start: \(model.errorMessage ?? "no error")")
    let sessionID = try XCTUnwrap(model.conversation.currentSessionID)
    let input = try XCTUnwrap(glasses).services.input
    // Each problem is filed on its own; the sample photo's second problem is prepared too.
    func firstProblems() -> [ConversationEntry] {
      model.conversation.entries(inSession: sessionID).filter { $0.prompt == "Problem 1" }
    }

    for press in 1...2 {
      let buttonReady = await waitUntil(20) { model.shutterStatus == .active && !model.isBusy }
      XCTAssertTrue(buttonReady, "press \(press): button not ready (\(model.shutterStatus), busy \(model.isBusy))")
      try await Task.sleep(for: .seconds(1))  // clear of the press debounce
      input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
      let answered = await waitUntil(60) { firstProblems().count == press && !model.isBusy }
      XCTAssertTrue(answered, "press \(press): no answer filed")
      let entry = try XCTUnwrap(firstProblems().last)
      XCTAssertNil(entry.error, "press \(press) failed: \(entry.error ?? "")")
      XCTAssertNotNil(entry.answer)
      XCTAssertNotNil(entry.photoFile, "press \(press): photo wasn't saved")
    }

    model.stopSession()
    XCTAssertFalse(model.sessionActive)
    XCTAssertNil(model.conversation.currentSessionID)
    XCTAssertTrue(model.conversation.pastSessions.contains { $0.id == sessionID })
  }

  /// A press while the last photo is still being solved is ignored (one physical press never
  /// starts two solves). Once the answer has come, the buttons work on it: a swipe moves to
  /// the second problem, a double press checks it, and a new press takes a new photo.
  func testMathButtonsInTestMode() async throws {
    let model = AppModel()
    let wasTestMode = model.testMode
    let wasSubject = model.subject
    model.testMode = true
    model.subject = .math
    // A long stand-in for Claude, so the second press comes while the first is still working.
    AppModel.testModeWait = .seconds(15)
    defer {
      model.testMode = wasTestMode
      model.subject = wasSubject
      AppModel.testModeWait = .seconds(2)
    }

    let ready = await waitUntil(10) { model.isRegistered && model.hasActiveDevice }
    XCTAssertTrue(ready, "registered \(model.isRegistered), glasses \(model.hasActiveDevice)")
    await model.startSession(prompt: model.subject.defaultPrompt)
    XCTAssertTrue(model.sessionActive, "session didn't start: \(model.errorMessage ?? "no error")")
    let sessionID = try XCTUnwrap(model.conversation.currentSessionID)
    let input = try XCTUnwrap(glasses).services.input
    func entries(_ prompt: String) -> [ConversationEntry] {
      model.conversation.entries(inSession: sessionID).filter { $0.prompt == prompt }
    }
    func buttonBack() async -> Bool {
      await waitUntil(30) { model.shutterStatus == .active }
    }

    let buttonReady = await waitUntil(20) { model.shutterStatus == .active && !model.isBusy }
    XCTAssertTrue(buttonReady, "button not ready (\(model.shutterStatus), busy \(model.isBusy))")
    try await Task.sleep(for: .seconds(1))
    input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
    let thinking = await waitUntil(30) { model.phase == .thinking }
    XCTAssertTrue(thinking, "the photo never got to Claude (phase \(model.phase))")

    // A second press while it's solving does nothing.
    let backAfterPhoto = await waitUntil(30) {
      DiagnosticsLog.shared.text.contains("glasses session refreshed") && model.shutterStatus == .active
    }
    XCTAssertTrue(backAfterPhoto, "button didn't come back after the photo (\(model.shutterStatus))")
    try await Task.sleep(for: .seconds(1))
    input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
    let ignored = await waitUntil(5) { DiagnosticsLog.shared.text.contains("press ignored") }
    XCTAssertTrue(ignored, "a press while solving wasn't ignored")
    AppModel.testModeWait = .seconds(2)

    let answered = await waitUntil(60) { model.workspace?.current?.answer.isEmpty == false }
    XCTAssertTrue(answered, "the first problem wasn't answered")
    XCTAssertEqual(model.workspace?.labels, ["1", "2"])
    XCTAssertEqual(entries("Problem 1").count, 1)

    // Swipe: the second problem, from the same photo.
    let backForSwipe = await buttonBack()
    XCTAssertTrue(backForSwipe)
    input.navRight(source: MWDATMockDevice.InputSource.captouch)
    let moved = await waitUntil(10) { model.workspace?.index == 1 }
    XCTAssertTrue(moved, "the swipe didn't move to problem 2")
    let second = await waitUntil(60) { model.workspace?.current?.answer == "x equals 4." }
    XCTAssertTrue(second, "problem 2 wasn't prepared")

    // Double press: Check, with no new photo.
    try await Task.sleep(for: .seconds(1))
    input.capture(pressType: MWDATMockDevice.CapturePressType.doublePress)
    let checked = await waitUntil(60) { model.workspace?.current?.check != nil }
    XCTAssertTrue(checked, "the check didn't finish")
    XCTAssertEqual(model.workspace?.current?.check?.hasPrefix("Correct"), true)
    XCTAssertEqual(entries("Check problem 2").count, 1)

    // A new press after the answer: a new photo.
    try await Task.sleep(for: .seconds(1))
    input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
    let newPhoto = await waitUntil(60) { entries("Problem 1").count == 2 }
    XCTAssertTrue(newPhoto, "a press after the answer didn't take a new photo")
    XCTAssertEqual(model.workspace?.index, 0)
    model.stopSession()
  }
}

@MainActor
private final class EventCounter {
  var gestures: [ShutterButton.Gesture] = []
}

/// Media files for the simulated camera.
enum TestMedia {
  static func imageFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "problem.png")
    try TestImages.image().pngData()!.write(to: url)
    return url
  }

  /// Two seconds of 360×640 H.264 video for the simulated camera feed.
  @MainActor
  static func videoFile() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "feed.mp4")
    try? FileManager.default.removeItem(at: url)
    let width = 360
    let height = 640
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
      guard let buffer else { continue }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, Int32(frame * 4 % 255), CVPixelBufferGetDataSize(buffer))
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      writer.finishWriting { done.resume() }
    }
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
  }
}
