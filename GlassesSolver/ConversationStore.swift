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
  /// The hands-free session this belongs to; nil for the in-app Solve button.
  var sessionID: UUID? = nil
}

/// One hands-free session: its own chat, archived when the session ends.
struct ConversationSession: Codable, Identifiable, Sendable {
  let id: UUID
  let started: Date
  var ended: Date?
  let prompt: String
}

/// The history behind the Conversation screen, saved in the app's Documents folder so it
/// survives restarts. Each hands-free session is its own chat; answers from the in-app
/// Solve button are grouped by day. Keeps the most recent `maxEntries` answers.
@Observable
@MainActor
final class ConversationStore {
  private static let maxEntries = 300
  /// Saved photos are downsized; the screen only shows thumbnails and a tap-to-enlarge view.
  private static let photoLongEdge: CGFloat = 1024

  private(set) var entries: [ConversationEntry] = []
  private(set) var sessions: [ConversationSession] = []
  /// The session in progress, if any.
  private(set) var currentSessionID: UUID?

  @ObservationIgnored private let folder: URL
  @ObservationIgnored private var historyFile: URL { folder.appending(path: "history.json") }

  private struct Saved: Codable {
    var sessions: [ConversationSession]
    var entries: [ConversationEntry]
  }

  init() {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    folder = documents.appending(path: "Conversation", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    load()
  }

  // MARK: - Sessions

  var currentSession: ConversationSession? {
    currentSessionID.flatMap { id in sessions.first { $0.id == id } }
  }

  /// Ended sessions that have at least one answer, newest first.
  var pastSessions: [ConversationSession] {
    Array(sessions.filter { $0.ended != nil && !entries(inSession: $0.id).isEmpty }.reversed())
  }

  func beginSession(prompt: String) {
    endSession()
    let session = ConversationSession(id: UUID(), started: .now, ended: nil, prompt: prompt)
    sessions.append(session)
    currentSessionID = session.id
    save()
  }

  /// Archives the current session's chat; the next session starts a new one.
  func endSession() {
    guard let id = currentSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else {
      currentSessionID = nil
      return
    }
    sessions[index].ended = .now
    currentSessionID = nil
    // Kept even if empty for now: an answer still in progress can arrive after the session
    // ends. Empty ended sessions are hidden from the list and pruned on the next launch.
    save()
  }

  func entries(inSession id: UUID) -> [ConversationEntry] {
    entries.filter { $0.sessionID == id }
  }

  func deleteSession(_ id: UUID) {
    entries.filter { $0.sessionID == id }.forEach(deletePhoto)
    entries.removeAll { $0.sessionID == id }
    sessions.removeAll { $0.id == id }
    if currentSessionID == id { currentSessionID = nil }
    save()
  }

  // MARK: - Solve-button answers, by day

  /// Days with Solve-button answers, newest first.
  var solveButtonDays: [Date] {
    let days = Set(entries.filter { $0.sessionID == nil }.map { Calendar.current.startOfDay(for: $0.date) })
    return days.sorted(by: >)
  }

  func solveButtonEntries(on day: Date) -> [ConversationEntry] {
    entries.filter { $0.sessionID == nil && Calendar.current.isDate($0.date, inSameDayAs: day) }
  }

  func deleteSolveButtonDay(_ day: Date) {
    let doomed = solveButtonEntries(on: day)
    doomed.forEach(deletePhoto)
    let ids = Set(doomed.map(\.id))
    entries.removeAll { ids.contains($0.id) }
    save()
  }

  // MARK: - Entries

  /// `sessionID` is the session the solve started in (it may have ended since).
  func add(
    prompt: String, photo: Data?, answer: String?, error: String?, isTest: Bool, sessionID: UUID?
  ) {
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
        photoFile: photoFile,
        sessionID: sessionID.flatMap { id in sessions.contains { $0.id == id } ? id : nil }))
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
    sessions.removeAll { $0.id != currentSessionID }
    save()
  }

  private func deletePhoto(of entry: ConversationEntry) {
    guard let url = photoURL(for: entry) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Saving

  private func load() {
    guard let data = try? Data(contentsOf: historyFile) else { return }
    if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
      entries = saved.entries
      sessions = saved.sessions
    } else if let legacy = try? JSONDecoder().decode([ConversationEntry].self, from: data) {
      entries = legacy  // the first version saved a bare list, all from before sessions had chats
    } else {
      diag("history", "couldn't read the saved conversation")
      return
    }
    // A session still open from a previous launch ended when the app did.
    for index in sessions.indices where sessions[index].ended == nil {
      let last = entries.last { $0.sessionID == sessions[index].id }?.date
      sessions[index].ended = last ?? sessions[index].started
    }
    // Drop sessions that never got an answer.
    let used = Set(entries.compactMap(\.sessionID))
    sessions.removeAll { !used.contains($0.id) }
  }

  private func save() {
    do {
      try JSONEncoder().encode(Saved(sessions: sessions, entries: entries))
        .write(to: historyFile, options: .atomic)
    } catch {
      diag("history", "couldn't save the conversation: \(ErrorDetail.describe(error))")
    }
  }
}
