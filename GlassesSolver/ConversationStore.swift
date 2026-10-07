import Foundation
import Observation
import UIKit

/// One solve: the photo and prompt sent, and the answer (or what went wrong).
struct ConversationEntry: Codable, Identifiable, Sendable {
  let id: UUID
  let date: Date
  let prompt: String
  let answer: String?
  let error: String?
  /// Test mode: Claude wasn't called and the answer is a sample.
  let isTest: Bool
  /// File name of the saved photo in the conversation folder, if there was one.
  let photoFile: String?
}

/// The history behind the Conversation screen, saved in the app's Documents folder so it
/// survives restarts. Keeps the most recent `maxEntries`.
@Observable
@MainActor
final class ConversationStore {
  private static let maxEntries = 100
  /// Saved photos are downsized; the screen only shows thumbnails and a tap-to-enlarge view.
  private static let photoLongEdge: CGFloat = 1024

  private(set) var entries: [ConversationEntry] = []
  @ObservationIgnored private let folder: URL
  @ObservationIgnored private var historyFile: URL { folder.appending(path: "history.json") }

  init() {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    folder = documents.appending(path: "Conversation", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    load()
  }

  func add(prompt: String, photo: Data?, answer: String?, error: String?, isTest: Bool) {
    let id = UUID()
    var photoFile: String?
    if let photo, let jpeg = ClaudeClient.preparedJPEG(from: photo, maxLongEdge: Self.photoLongEdge) {
      let name = id.uuidString + ".jpg"
      do {
        try jpeg.write(to: folder.appending(path: name), options: .atomic)
        photoFile = name
      } catch {
        diag("history", "couldn't save the photo: \(ErrorDetail.describe(error))")
      }
    }
    entries.append(
      ConversationEntry(
        id: id, date: .now, prompt: prompt, answer: answer, error: error, isTest: isTest,
        photoFile: photoFile))
    while entries.count > Self.maxEntries {
      deletePhoto(of: entries.removeFirst())
    }
    save()
  }

  func photoURL(for entry: ConversationEntry) -> URL? {
    entry.photoFile.map { folder.appending(path: $0) }
  }

  func clear() {
    entries.forEach(deletePhoto)
    entries.removeAll()
    save()
  }

  private func deletePhoto(of entry: ConversationEntry) {
    guard let url = photoURL(for: entry) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func load() {
    guard let data = try? Data(contentsOf: historyFile) else { return }
    do {
      entries = try JSONDecoder().decode([ConversationEntry].self, from: data)
    } catch {
      diag("history", "couldn't read the saved conversation: \(ErrorDetail.describe(error))")
    }
  }

  private func save() {
    do {
      try JSONEncoder().encode(entries).write(to: historyFile, options: .atomic)
    } catch {
      diag("history", "couldn't save the conversation: \(ErrorDetail.describe(error))")
    }
  }
}
