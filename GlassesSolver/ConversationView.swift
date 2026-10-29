import SwiftUI
import UIKit

/// History: every hands-free session and the iPhone's Solve answers, grouped by day, newest
/// first. A utility list, not a chat.
struct HistoryView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var confirmClear = false

  enum Route: Hashable {
    case session(UUID)
    case solveButton(Date)
  }

  struct Row: Identifiable {
    let route: Route
    let date: Date
    let subject: String
    let topic: String
    let isLive: Bool
    var id: Route { route }
  }

  struct DayGroup: Identifiable {
    let title: String
    var rows: [Row]
    var id: String { title }
  }

  private var store: ConversationStore { model.conversation }

  private var rows: [Row] {
    var sessions = store.pastSessions
    if let current = store.currentSession, !store.entries(inSession: current.id).isEmpty {
      sessions.insert(current, at: 0)
    }
    var rows = sessions.map { session in
      let entries = store.entries(inSession: session.id)
      return Row(
        route: .session(session.id), date: session.started, subject: Self.subjectTitle(entries),
        topic: Self.topic(entries), isLive: session.id == store.currentSessionID)
    }
    rows += store.solveButtonDays.map { day in
      let entries = store.solveButtonEntries(on: day)
      return Row(
        route: .solveButton(day), date: entries.last?.date ?? day, subject: Self.subjectTitle(entries),
        topic: Self.topic(entries), isLive: false)
    }
    return rows.sorted { $0.date > $1.date }
  }

  private var groups: [DayGroup] {
    var groups: [DayGroup] = []
    for row in rows {
      let title = Self.dayTitle(row.date)
      if groups.last?.title == title {
        groups[groups.count - 1].rows.append(row)
      } else {
        groups.append(DayGroup(title: title, rows: [row]))
      }
    }
    return groups
  }

  var body: some View {
    NavigationStack {
      List {
        if groups.isEmpty {
          ContentUnavailableView(
            "No History", systemImage: "clock",
            description: Text("Solved problems appear here."))
          .listRowBackground(Color.clear)
        }
        ForEach(groups) { group in
          Section(group.title) {
            ForEach(group.rows) { row in
              NavigationLink(value: row.route) { HistoryRow(row: row) }
            }
            .onDelete { offsets in offsets.map { group.rows[$0].route }.forEach(delete) }
          }
        }
      }
      .navigationTitle("History")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: Route.self) { route in
        HistoryDetailView(model: model, route: route)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Delete All", role: .destructive) { confirmClear = true }
            .disabled(store.entries.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .alert("Delete All History?", isPresented: $confirmClear) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) { store.clear() }
      } message: {
        Text("This cannot be undone.")
      }
    }
    .preferredColorScheme(.dark)
  }

  private func delete(_ route: Route) {
    switch route {
    case .session(let id): store.deleteSession(id)
    case .solveButton(let day): store.deleteSolveButtonDay(day)
    }
  }

  /// "Math 131" or "Chemistry", from what the answers were filed under.
  static func subjectTitle(_ entries: [ConversationEntry]) -> String {
    switch entries.first(where: { $0.subject != nil })?.subject {
    case ClaudeClient.Subject.math.rawValue: ClaudeClient.Subject.math.title
    case ClaudeClient.Subject.chemistry.rawValue: ClaudeClient.Subject.chemistry.title
    default: "Solved"
    }
  }

  /// What was solved, in a few words: the first answer's title, and how many more.
  static func topic(_ entries: [ConversationEntry]) -> String {
    let titles = entries.compactMap(entryTitle)
    guard let first = titles.first else { return entries.count == 1 ? "1 answer" : "\(entries.count) answers" }
    return titles.count > 1 ? "\(first) + \(titles.count - 1) more" : first
  }

  /// A few words for one answer: its saved title, the question it answered, or the questions on
  /// its page.
  static func entryTitle(_ entry: ConversationEntry) -> String? {
    if let title = entry.title, !title.isEmpty { return title.prefix(1).uppercased() + title.dropFirst() }
    guard let answer = entry.answer else { return nil }
    let lines = answer.components(separatedBy: "\n")
    if let question = lines.first(where: { $0.hasPrefix("Question: ") }) {
      let text = question.dropFirst("Question: ".count)
      return text.prefix(1).uppercased() + text.dropFirst()
    }
    let labels = AppModel.questions(in: answer).map(\.label)
    guard !labels.isEmpty else { return nil }
    return (labels.count == 1 ? "Question " : "Questions ") + labels.prefix(6).joined(separator: ", ")
  }

  static func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).month().day())
  }
}

private struct HistoryRow: View {
  let row: HistoryView.Row

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if row.isLive {
            Circle()
              .fill(Theme.accent)
              .frame(width: 6, height: 6)
              .accessibilityLabel("In progress")
          }
          Text(row.subject)
            .font(.headline)
        }
        Text(row.topic)
          .font(.subheadline)
          .foregroundStyle(Theme.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(row.date.formatted(date: .omitted, time: .shortened))
        .font(.subheadline)
        .foregroundStyle(Theme.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// One session's (or one day's) solved problems: photo, result, written answer, play again.
private struct HistoryDetailView: View {
  let model: AppModel
  let route: HistoryView.Route
  @State private var written: WrittenItem?
  @State private var photo: UIImage?
  @State private var showPhoto = false

  struct WrittenItem: Identifiable {
    let id = UUID()
    let entry: ConversationEntry
    let photo: UIImage?
  }

  /// Read live, so answers arriving during the current session appear as they come in.
  private var entries: [ConversationEntry] {
    switch route {
    case .session(let id): model.conversation.entries(inSession: id)
    case .solveButton(let day): model.conversation.solveButtonEntries(on: day)
    }
  }

  private var title: String {
    switch route {
    case .session(let id):
      let started = model.conversation.sessions.first { $0.id == id }?.started ?? .now
      return HistoryView.subjectTitle(entries) + " · " + started.formatted(date: .omitted, time: .shortened)
    case .solveButton(let day):
      return HistoryView.dayTitle(day)
    }
  }

  var body: some View {
    List {
      if entries.isEmpty {
        ContentUnavailableView(
          "Nothing Solved Yet", systemImage: "camera.viewfinder",
          description: Text("Answers from this session appear here."))
        .listRowBackground(Color.clear)
      }
      ForEach(entries) { entry in
        HistoryEntryRow(
          entry: entry, photo: image(for: entry),
          onPhoto: {
            photo = image(for: entry)
            showPhoto = true
          },
          onWritten: { written = WrittenItem(entry: entry, photo: image(for: entry)) },
          onReplay: { model.replay(entry) })
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showPhoto) { PhotoDetailView(image: photo) }
    .fullScreenCover(item: $written) { item in
      WrittenAnswerScreen(
        answer: item.entry.answer ?? "", photo: item.photo,
        title: HistoryView.entryTitle(item.entry) ?? item.entry.prompt,
        onReplay: { model.replay(item.entry) })
    }
  }

  private func image(for entry: ConversationEntry) -> UIImage? {
    model.conversation.photoURL(for: entry).flatMap { UIImage(contentsOfFile: $0.path()) }
  }
}

private struct HistoryEntryRow: View {
  let entry: ConversationEntry
  let photo: UIImage?
  let onPhoto: () -> Void
  let onWritten: () -> Void
  let onReplay: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let photo {
        Button(action: onPhoto) {
          Image(uiImage: photo)
            .resizable()
            .scaledToFill()
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Photo. Opens it full screen.")
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(heading)
          .font(.caption)
          .foregroundStyle(Theme.secondary)
        if let result {
          Text(result)
            .lineLimit(3)
        }
        if let error = entry.error {
          Text(ContentView.shortError(error))
            .font(.subheadline)
            .foregroundStyle(.red)
        }
        if entry.isTest {
          Text("Test Mode sample")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        if let answer = entry.answer {
          HStack(spacing: 20) {
            if !WrittenAnswer.parse(answer).isEmpty {
              Button("Written Answer", action: onWritten)
            }
            Button("Play Again", action: onReplay)
          }
          .font(.subheadline)
          .buttonStyle(.borderless)
        }
      }
    }
    .padding(.vertical, 6)
  }

  private var heading: String {
    (HistoryView.entryTitle(entry) ?? entry.prompt) + " · " + entry.date.formatted(date: .omitted, time: .shortened)
  }

  /// The result in a line: the answer or check result, or a chemistry page's first answer.
  private var result: String? {
    guard let answer = entry.answer else { return nil }
    let lines = answer.components(separatedBy: "\n")
    for prefix in ["The answer: ", "Check: "] {
      if let line = lines.first(where: { $0.hasPrefix(prefix) }) { return String(line.dropFirst(prefix.count)) }
    }
    let answers = lines.filter { $0.lowercased().hasPrefix("answer:") }.map { Speaker.spokenPart(String($0.dropFirst(7))) }
    guard let first = answers.first else { return nil }
    return answers.count > 1 ? "\(first.trimmingCharacters(in: .whitespaces)) + \(answers.count - 1) more" : first
  }
}
