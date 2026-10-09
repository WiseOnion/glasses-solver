import SwiftUI
import UIKit

/// The list of chats: the session in progress, past sessions (each archived when it ended),
/// and in-app Solve-button answers by day. Opens straight into the current session's chat
/// when one is running.
struct ConversationView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var path: [ChatRoute] = []
  @State private var confirmClear = false
  @State private var didOpenCurrentSession = false

  enum ChatRoute: Hashable {
    case session(UUID)
    case solveButton(Date)
  }

  private var store: ConversationStore { model.conversation }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if let current = store.currentSession {
          Section("Now") {
            NavigationLink(value: ChatRoute.session(current.id)) {
              SessionRow(
                title: "Current session", subtitle: current.prompt,
                count: store.entries(inSession: current.id).count, isLive: true)
            }
          }
        }
        if !store.pastSessions.isEmpty {
          Section("Past sessions") {
            ForEach(store.pastSessions) { session in
              NavigationLink(value: ChatRoute.session(session.id)) {
                SessionRow(
                  title: Self.sessionTitle(session), subtitle: session.prompt,
                  count: store.entries(inSession: session.id).count, isLive: false)
              }
            }
            .onDelete { offsets in
              let doomed = offsets.map { store.pastSessions[$0].id }
              doomed.forEach(store.deleteSession)
            }
          }
        }
        if !store.solveButtonDays.isEmpty {
          Section("Solve button") {
            ForEach(store.solveButtonDays, id: \.self) { day in
              NavigationLink(value: ChatRoute.solveButton(day)) {
                SessionRow(
                  title: day.formatted(date: .complete, time: .omitted), subtitle: nil,
                  count: store.solveButtonEntries(on: day).count, isLive: false)
              }
            }
            .onDelete { offsets in
              let doomed = offsets.map { store.solveButtonDays[$0] }
              doomed.forEach(store.deleteSolveButtonDay)
            }
          }
        }
        if store.currentSession == nil && store.pastSessions.isEmpty && store.solveButtonDays.isEmpty {
          ContentUnavailableView(
            "No answers yet", systemImage: "bubble.left.and.bubble.right",
            description: Text("Each session gets its own chat here, saved when the session ends."))
        }
      }
      .navigationTitle("Conversations")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: ChatRoute.self) { route in
        switch route {
        case .session(let id):
          let session = store.sessions.first { $0.id == id }
          ChatView(
            model: model,
            title: session.map { $0.id == store.currentSessionID ? "Current session" : Self.sessionTitle($0) }
              ?? "Session",
            route: route)
        case .solveButton(let day):
          ChatView(
            model: model, title: day.formatted(date: .abbreviated, time: .omitted), route: route)
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Clear all", role: .destructive) { confirmClear = true }
            .disabled(store.entries.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .confirmationDialog("Delete every saved chat, answer and photo?", isPresented: $confirmClear) {
        Button("Delete all", role: .destructive) { store.clear() }
      }
      .onAppear {
        // Once per opening; Back from the chat should stay on the list.
        guard !didOpenCurrentSession else { return }
        didOpenCurrentSession = true
        if let current = store.currentSessionID { path = [.session(current)] }
      }
    }
  }

  static func sessionTitle(_ session: ConversationSession) -> String {
    let start = session.started.formatted(date: .abbreviated, time: .shortened)
    guard let ended = session.ended else { return start }
    return start + " – " + ended.formatted(date: .omitted, time: .shortened)
  }
}

private struct SessionRow: View {
  let title: String
  let subtitle: String?
  let count: Int
  let isLive: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if isLive {
          Circle().fill(.green).frame(width: 8, height: 8)
        }
        Text(title).font(.headline)
        Spacer()
        Text(count == 1 ? "1 answer" : "\(count) answers")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let subtitle {
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

/// One chat: your photo and prompt on the right, the answer on the left.
private struct ChatView: View {
  let model: AppModel
  let title: String
  let route: ConversationView.ChatRoute
  @State private var enlargedPhoto: URL?

  /// Read live, so answers arriving during the current session appear as they come in.
  private var entries: [ConversationEntry] {
    switch route {
    case .session(let id): model.conversation.entries(inSession: id)
    case .solveButton(let day): model.conversation.solveButtonEntries(on: day)
    }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if entries.isEmpty {
          ContentUnavailableView(
            "No answers yet", systemImage: "camera.viewfinder",
            description: Text("Press the capture button on your glasses; answers in this session show up here."))
        }
        ForEach(entries) { entry in
          EntryView(
            entry: entry, photoURL: model.conversation.photoURL(for: entry),
            onReplay: { model.replay(entry) },
            onPhotoTap: { enlargedPhoto = model.conversation.photoURL(for: entry) })
        }
      }
      .padding()
    }
    .defaultScrollAnchor(.bottom)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $enlargedPhoto) { url in
      PhotoView(url: url)
    }
  }
}

private struct EntryView: View {
  let entry: ConversationEntry
  let photoURL: URL?
  let onReplay: () -> Void
  let onPhotoTap: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.date.formatted(date: .abbreviated, time: .shortened))
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)

      // You: the photo and the prompt.
      VStack(alignment: .trailing, spacing: 6) {
        if let photoURL, let image = UIImage(contentsOfFile: photoURL.path()) {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 180, height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(perform: onPhotoTap)
            .accessibilityLabel("Photo from the glasses. Tap to enlarge.")
        }
        Text(entry.prompt)
          .font(.subheadline)
          .padding(10)
          .foregroundStyle(.white)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.leading, 48)

      // Claude: the answer, or what went wrong.
      VStack(alignment: .leading, spacing: 8) {
        if entry.isTest {
          Label("Test mode sample, not from Claude", systemImage: "testtube.2")
            .font(.caption.bold())
            .foregroundStyle(.orange)
        }
        if let answer = entry.answer {
          let written = WrittenAnswer.parse(answer)
          if written.isEmpty {
            ForEach(Array(answer.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
              AnswerLine(line: Speaker.spokenPart(line))
            }
          } else {
            WrittenAnswerView(data: written.pageData(now: nil))
              .frame(height: 380)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          Button("Play again", systemImage: "speaker.wave.2", action: onReplay)
            .font(.caption)
            .buttonStyle(.bordered)
        } else if let error = entry.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      .textSelection(.enabled)
      .padding(12)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
      .padding(.trailing, 32)
    }
  }
}

/// One line of an answer. "Write:" lines are shown as the line to copy.
private struct AnswerLine: View {
  let line: String

  var body: some View {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("write:") {
      Label {
        Text(trimmed.dropFirst("write:".count).trimmingCharacters(in: .whitespaces))
          .font(.body.monospaced().weight(.semibold))
      } icon: {
        Image(systemName: "pencil.line")
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    } else if !trimmed.isEmpty {
      Text(trimmed)
    }
  }
}

private struct PhotoView: View {
  let url: URL
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if let image = UIImage(contentsOfFile: url.path()) {
          Image(uiImage: image).resizable().scaledToFit()
        } else {
          ContentUnavailableView("Photo not found", systemImage: "photo")
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

extension URL: @retroactive Identifiable {
  public var id: String { absoluteString }
}
