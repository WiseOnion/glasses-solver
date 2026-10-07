import SwiftUI
import UIKit

/// Chat-style history of every solve: your photo and prompt on the right, the answer on
/// the left, with "Write:" lines set apart the way you'd copy them.
struct ConversationView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var confirmClear = false
  @State private var enlargedPhoto: URL?

  private var store: ConversationStore { model.conversation }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          if store.entries.isEmpty {
            ContentUnavailableView(
              "No answers yet", systemImage: "bubble.left.and.bubble.right",
              description: Text("Each photo you solve and its answer will appear here."))
          }
          ForEach(store.entries) { entry in
            EntryView(
              entry: entry, photoURL: store.photoURL(for: entry),
              onReplay: { model.replay(entry) },
              onPhotoTap: { enlargedPhoto = store.photoURL(for: entry) })
          }
        }
        .padding()
      }
      .defaultScrollAnchor(.bottom)
      .navigationTitle("Conversation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Clear", role: .destructive) { confirmClear = true }
            .disabled(store.entries.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .confirmationDialog("Delete all saved answers and photos?", isPresented: $confirmClear) {
        Button("Delete all", role: .destructive) { store.clear() }
      }
      .sheet(item: $enlargedPhoto) { url in
        PhotoView(url: url)
      }
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
          ForEach(Array(answer.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
            AnswerLine(line: line)
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
