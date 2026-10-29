import SwiftUI
import UIKit

/// History: every hands-free session and the iPhone's Solve answers, grouped by day, newest
/// first. A utility list, not a chat.
struct HistoryView: View {
  let model: AppModel
  @State private var confirmClear = false

  enum Route: Hashable {
    case session(UUID)
    case solveButton(Date)
  }

  struct Row: Identifiable {
    let route: Route
    let date: Date
    let subject: String
    let symbol: String
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
        symbol: Self.subjectSymbol(entries), topic: Self.topic(entries), isLive: session.id == store.currentSessionID)
    }
    rows += store.solveButtonDays.map { day in
      let entries = store.solveButtonEntries(on: day)
      return Row(
        route: .solveButton(day), date: entries.last?.date ?? day, subject: Self.subjectTitle(entries),
        symbol: Self.subjectSymbol(entries), topic: Self.topic(entries), isLive: false)
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
          VStack(spacing: 4) {
            Text("No History")
              .font(.headline)
            Text("Solved problems will appear here.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 120)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
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
      .listStyle(.plain)
      .navigationTitle("History")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: Route.self) { route in
        HistoryDetailView(model: model, route: route)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Clear All") { confirmClear = true }
            .disabled(store.entries.isEmpty)
        }
      }
      .alert("Delete All?", isPresented: $confirmClear) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) { store.clear() }
      } message: {
        Text("This will permanently delete your saved history.")
      }
    }
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

  static func subjectSymbol(_ entries: [ConversationEntry]) -> String {
    entries.first(where: { $0.subject != nil })?.subject == ClaudeClient.Subject.chemistry.rawValue
      ? ClaudeClient.Subject.chemistry.symbol : ClaudeClient.Subject.math.symbol
  }

  /// What was solved: how many problems (or questions), then the first one's topic.
  static func topic(_ entries: [ConversationEntry]) -> String {
    let solved = entries.filter { !$0.prompt.hasPrefix("Check") && $0.answer != nil }
    let questions = solved.reduce(0) { $0 + AppModel.questions(in: $1.answer ?? "").count }
    let isChemistry = solved.contains { $0.subject == ClaudeClient.Subject.chemistry.rawValue }
    let count =
      isChemistry
      ? (questions == 1 ? "1 question" : "\(questions) questions")
      : (solved.count == 1 ? "1 problem" : "\(solved.count) problems")
    guard let first = solved.compactMap(entryTitle).first, !isChemistry else { return count }
    return count + " · " + first
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
    HStack(spacing: 14) {
      Image(systemName: row.symbol)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.subject)
            .font(.body)
          if row.isLive {
            Circle()
              .fill(Theme.connected)
              .frame(width: 6, height: 6)
              .accessibilityLabel("In progress")
          }
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

  private var date: Date {
    switch route {
    case .session(let id): model.conversation.sessions.first { $0.id == id }?.started ?? .now
    case .solveButton(let day): day
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
        Section(Self.heading(entry)) {
          HistoryEntryRow(
            entry: entry, photo: image(for: entry),
            onPhoto: {
              photo = image(for: entry)
              showPhoto = true
            })
          if let answer = entry.answer {
            Button {
              model.replay(entry)
            } label: {
              Label("Play Again", systemImage: "play.circle")
            }
            if !WrittenAnswer.parse(answer).isEmpty {
              Button {
                written = WrittenItem(entry: entry, photo: image(for: entry))
              } label: {
                HStack {
                  Label("Written Answer", systemImage: "doc.text")
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                }
              }
            }
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 0) {
          Text(HistoryView.subjectTitle(entries))
            .font(.headline)
          Text(date.formatted(.dateTime.month(.wide).day()))
            .font(.caption)
            .foregroundStyle(Theme.secondary)
        }
      }
    }
    .listStyle(.grouped)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showPhoto) { PhotoDetailView(image: photo) }
    .fullScreenCover(item: $written) { item in
      WrittenAnswerScreen(
        answer: item.entry.answer ?? "", photo: item.photo,
        title: HistoryView.entryTitle(item.entry) ?? item.entry.prompt,
        onReplay: { model.replay(item.entry) })
    }
  }

  /// "Problem 4", "Check problem 4", or a chemistry page's questions.
  static func heading(_ entry: ConversationEntry) -> String {
    if let label = entry.answer.flatMap({ Speaker.problemLabel(in: $0.components(separatedBy: "\n").first ?? "") }),
      !entry.prompt.hasPrefix("Check"), entry.subject == ClaudeClient.Subject.math.rawValue
    {
      return "Problem \(label)"
    }
    if entry.subject == ClaudeClient.Subject.chemistry.rawValue, let title = HistoryView.entryTitle(entry) {
      return title
    }
    return entry.prompt
  }

  private func image(for entry: ConversationEntry) -> UIImage? {
    model.conversation.photoURL(for: entry).flatMap { UIImage(contentsOfFile: $0.path()) }
  }
}

private struct HistoryEntryRow: View {
  let entry: ConversationEntry
  let photo: UIImage?
  let onPhoto: () -> Void

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
      }
    }
    .padding(.vertical, 6)
  }

  private var heading: String {
    let title = entry.prompt.hasPrefix("Check") ? nil : HistoryView.entryTitle(entry)
    return (title.map { $0 + " · " } ?? "") + entry.date.formatted(date: .omitted, time: .shortened)
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
