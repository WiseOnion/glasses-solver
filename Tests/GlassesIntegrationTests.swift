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

  /// A short capture press and a touchpad double-tap reach the app; hold and double press
  /// of the capture button are ignored.
  func testCapturePressAndDoubleTapReachTheApp() async throws {
    let (camera, _) = await makeCamera()
    let session = try await camera.startedSession()
    let shutter = ShutterButton()
    let events = EventCounter()
    shutter.attach(
      to: session,
      onPress: { _ in events.presses += 1 },
      onSelect: { events.selects += 1 },
      onStatus: { _ in })
    let active = await waitUntil(15) { shutter.status == .active }
    XCTAssertTrue(active, "button events never became active (status \(shutter.status))")

    let input = try XCTUnwrap(glasses).services.input
    input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
    let pressed = await waitUntil(5) { events.presses == 1 }
    XCTAssertTrue(pressed, "capture press didn't arrive")

    input.select(source: MWDATMockDevice.InputSource.captouch)
    let selected = await waitUntil(5) { events.selects == 1 }
    XCTAssertTrue(selected, "touchpad double-tap (select) didn't arrive")

    input.capture(pressType: MWDATMockDevice.CapturePressType.hold)
    input.capture(pressType: MWDATMockDevice.CapturePressType.doublePress)
    try await Task.sleep(for: .seconds(1))
    XCTAssertEqual(events.presses, 1, "hold or double press was treated as a solve")

    shutter.detach(from: session)
    camera.endSession()
  }

  /// The whole hands-free flow in Test mode (no Claude): two presses, two answers, both in
  /// the session's own chat, which is archived when the session stops.
  func testHandsFreeSessionInTestMode() async throws {
    let model = AppModel()
    let wasTestMode = model.testMode
    model.testMode = true
    defer { model.testMode = wasTestMode }

    let ready = await waitUntil(10) { model.isRegistered && model.hasActiveDevice }
    XCTAssertTrue(ready, "registered \(model.isRegistered), glasses \(model.hasActiveDevice)")
    await model.startSession(prompt: "Test prompt")
    XCTAssertTrue(model.sessionActive, "session didn't start: \(model.errorMessage ?? "no error")")
    let sessionID = try XCTUnwrap(model.conversation.currentSessionID)
    let input = try XCTUnwrap(glasses).services.input

    for press in 1...2 {
      let buttonReady = await waitUntil(20) { model.shutterStatus == .active && !model.isBusy }
      XCTAssertTrue(buttonReady, "press \(press): button not ready (\(model.shutterStatus), busy \(model.isBusy))")
      try await Task.sleep(for: .seconds(1))  // clear of the press debounce
      input.capture(pressType: MWDATMockDevice.CapturePressType.shortPress)
      let answered = await waitUntil(60) {
        model.conversation.entries(inSession: sessionID).count == press && !model.isBusy
      }
      XCTAssertTrue(answered, "press \(press): no answer filed")
      let entry = try XCTUnwrap(model.conversation.entries(inSession: sessionID).last)
      XCTAssertNil(entry.error, "press \(press) failed: \(entry.error ?? "")")
      XCTAssertNotNil(entry.answer)
      XCTAssertNotNil(entry.photoFile, "press \(press): photo wasn't saved")
    }

    model.stopSession()
    XCTAssertFalse(model.sessionActive)
    XCTAssertNil(model.conversation.currentSessionID)
    XCTAssertTrue(model.conversation.pastSessions.contains { $0.id == sessionID })
  }
}

@MainActor
private final class EventCounter {
  var presses = 0
  var selects = 0
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
