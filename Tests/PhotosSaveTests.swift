import Photos
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

  /// The real thing: a photo added through PhotoKit shows up in the library.
  func testPhotoAppearsInThePhotosLibrary() async throws {
    let model = AppModel()
    await model.setSavePhotos(true)
    defer { Task { await model.setSavePhotos(false) } }
    XCTAssertTrue(model.savePhotosToLibrary)
    let readAccess = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    try XCTSkipUnless(readAccess == .authorized, "can't read the library to check (access \(readAccess.rawValue))")
    let before = PHAsset.fetchAssets(with: .image, options: nil).count
    model.saveToPhotos(TestImages.jpeg())
    var after = before
    for _ in 0..<50 where after == before {
      try await Task.sleep(for: .milliseconds(100))
      after = PHAsset.fetchAssets(with: .image, options: nil).count
    }
    XCTAssertEqual(after, before + 1, "the photo didn't appear in Photos")
  }
}
