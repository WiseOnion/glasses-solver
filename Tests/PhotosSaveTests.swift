import XCTest

@testable import GlassesSolver

/// Save Photos to Photos: off unless turned on, and the photo really lands in the library.
/// CI grants the simulator's Photos access first (tests.yml), so no permission prompt appears.
@MainActor
final class PhotosSaveTests: XCTestCase {
  override func tearDown() async throws {
    AppModel.photoSaveOverride = nil
    try await super.tearDown()
  }

  func testOffByDefaultAndOffSavesNothing() async {
    UserDefaults.standard.removeObject(forKey: "savePhotosToLibrary")
    let model = AppModel()
    XCTAssertFalse(model.savePhotosToLibrary, "Save Photos to Photos should start off")
    var saved = 0
    AppModel.photoSaveOverride = { _ in saved += 1 }
    model.saveToPhotos(TestImages.jpeg())
    XCTAssertEqual(saved, 0)
  }

  func testOnHandsOverTheExactPhoto() async {
    let model = AppModel()
    await model.setSavePhotos(true)
    defer { Task { await model.setSavePhotos(false) } }
    XCTAssertTrue(model.savePhotosToLibrary, "access wasn't granted: \(model.errorMessage ?? "no error")")
    var saved: [Data] = []
    AppModel.photoSaveOverride = { saved.append($0) }
    let photo = TestImages.jpeg()
    model.saveToPhotos(photo)
    XCTAssertEqual(saved, [photo])
  }

  /// The real thing: PhotoKit adds the photo to the simulator's library. (The app only has
  /// add-only access, by design, so it can't count the library; PhotoKit's own report that the
  /// change was applied is the check.)
  func testPhotoIsAddedToThePhotosLibrary() async throws {
    let model = AppModel()
    await model.setSavePhotos(true)
    defer { Task { await model.setSavePhotos(false) } }
    XCTAssertTrue(model.savePhotosToLibrary, "access wasn't granted: \(model.errorMessage ?? "no error")")
    DiagnosticsLog.shared.clear()
    model.saveToPhotos(TestImages.jpeg())
    var added = false
    for _ in 0..<50 where !added {
      try await Task.sleep(for: .milliseconds(100))
      added = DiagnosticsLog.shared.text.contains("[photos] added the photo to Photos")
    }
    XCTAssertTrue(added, "PhotoKit didn't add the photo: \(DiagnosticsLog.shared.text)")
  }
}
