import Foundation
import Observation
import SwiftUI

/// A practice exam Claude wrote in the style of the course's tests: the problems, shown on the
/// phone's written page, and the worked answer key, locked until the exam is handed in.
struct PracticeExam: Codable, Equatable, Sendable {
  let created: Date
  let subject: String
  /// The problems, as "Problem:" and "Write:" lines with their LaTeX after "||".
  let exam: String
  /// The worked solutions, in the same form as an answer to a photo, so they can be dictated.
  let key: String
  var handedIn: Date?

  /// Claude's reply split at its "ANSWER KEY" line; nil if either half is missing.
  static func parse(_ reply: String, subject: ClaudeClient.Subject, now: Date = .now) -> PracticeExam? {
    let lines = reply.components(separatedBy: "\n")
    // Tolerates "Answer key:" or "**ANSWER KEY**".
    guard let split = lines.firstIndex(where: { $0.uppercased().filter(\.isLetter) == "ANSWERKEY" }) else {
      return nil
    }
    let exam = lines[..<split].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let key = lines[(split + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !exam.isEmpty, !key.isEmpty else { return nil }
    return PracticeExam(created: now, subject: subject.rawValue, exam: exam, key: key)
  }

  /// The exam and its key together, sent with a Check photo so the paper is marked against it.
  var withKey: String { exam + "\n\nANSWER KEY\n\n" + key }
}

/// A skill missed in a Check, which comes back in later practice exams.
struct ReviewItem: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  let subject: String
  let skill: String
  var due: Date
  /// How many practice exams it has been in since it was last missed.
  var step = 0
}

/// The current practice exam and the skills to review, saved in Documents/Study.
@Observable
@MainActor
final class StudyStore {
  /// Days until a skill comes back after each practice exam it's in; after the last, it's
  /// dropped. A missed skill is due at once, so it's in the very next exam.
  /// ponytail: being in an exam counts as practiced, whether or not it was then got right.
  /// A wrong answer in the next Check brings it back through its Review line, which resets it.
  static let intervals: [Double] = [3, 7, 14]

  private(set) var exam: PracticeExam?
  private(set) var reviews: [ReviewItem] = []

  @ObservationIgnored private let file: URL

  private struct Saved: Codable {
    var exam: PracticeExam?
    var reviews: [ReviewItem]
  }

  /// `folder` is for tests; the app uses Documents/Study.
  init(folder: URL? = nil) {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let folder = folder ?? documents.appending(path: "Study", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    file = folder.appending(path: "study.json")
    guard let data = try? Data(contentsOf: file) else { return }
    if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
      exam = saved.exam
      reviews = saved.reviews
    } else {
      diag("study", "couldn't read the saved practice exam and review list")
    }
  }

  /// The skill in a "Review:" line, if this line is one.
  nonisolated static func reviewSkill(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("review:") else { return nil }
    var skill = trimmed.dropFirst("review:".count).trimmingCharacters(in: .whitespaces)
    while skill.hasSuffix(".") { skill.removeLast() }
    return skill.isEmpty ? nil : skill
  }

  func reviews(for subject: ClaudeClient.Subject) -> [ReviewItem] {
    reviews.filter { $0.subject == subject.rawValue }.sorted { $0.due < $1.due }
  }

  func due(for subject: ClaudeClient.Subject, now: Date = .now) -> [ReviewItem] {
    reviews(for: subject).filter { $0.due <= now }
  }

  /// Saves each skill an answer's "Review:" lines name, due at once. One already on the list
  /// (the same words, any case) starts over.
  func recordMisses(in answer: String, subject: ClaudeClient.Subject, now: Date = .now) {
    let skills = answer.components(separatedBy: "\n").compactMap(Self.reviewSkill(in:))
    guard !skills.isEmpty else { return }
    for skill in skills {
      if let index = reviews.firstIndex(where: {
        $0.subject == subject.rawValue && $0.skill.caseInsensitiveCompare(skill) == .orderedSame
      }) {
        reviews[index].due = now
        reviews[index].step = 0
      } else {
        reviews.append(ReviewItem(subject: subject.rawValue, skill: skill, due: now))
      }
    }
    diag("study", "saved for review: \(skills.joined(separator: "; "))")
    save()
  }

  /// Makes `exam` the current one (replacing any other), and moves each skill it reviews
  /// to its next date.
  func startExam(_ exam: PracticeExam, reviewed: [ReviewItem], now: Date = .now) {
    self.exam = exam
    let ids = Set(reviewed.map(\.id))
    reviews = reviews.compactMap { item -> ReviewItem? in
      guard ids.contains(item.id) else { return item }
      guard item.step < Self.intervals.count else { return nil }
      var next = item
      next.due = now.addingTimeInterval(Self.intervals[item.step] * 24 * 60 * 60)
      next.step += 1
      return next
    }
    save()
  }

  /// Unlocks the answer key.
  func handIn(now: Date = .now) {
    guard exam != nil else { return }
    exam?.handedIn = now
    save()
  }

  func deleteReviews(_ ids: Set<UUID>) {
    reviews.removeAll { ids.contains($0.id) }
    save()
  }

  private func save() {
    do {
      try JSONEncoder().encode(Saved(exam: exam, reviews: reviews)).write(to: file, options: .atomic)
    } catch {
      diag("study", "couldn't save the practice exam and review list: \(ErrorDetail.describe(error))")
    }
  }
}

/// Practice exams like the real ones, and the skills that come back in them.
struct PracticeView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var topics = ""
  @State private var count = 6
  @State private var showExam = false
  @State private var showKey = false

  var body: some View {
    NavigationStack {
      Form {
        if let exam = model.study.exam {
          examSection(exam)
        }

        Section {
          TextField("Topics (optional), such as chain rule", text: $topics, axis: .vertical)
            .lineLimit(1...4)
          Stepper("\(count) problems", value: $count, in: 2...15)
          Button {
            Task { await model.writePracticeExam(count: count, topics: topics) }
          } label: {
            if model.isWritingExam {
              HStack {
                ProgressView()
                Text("Writing it\u{2026}")
              }
            } else {
              Label(
                model.study.exam == nil ? "Write practice exam" : "Write a new one", systemImage: "square.and.pencil")
            }
          }
          .disabled(model.isWritingExam || !model.canWriteExam)
        } header: {
          Text("New \(model.subject.name) exam")
        } footer: {
          Text(newExamFooter)
        }

        let reviews = model.study.reviews(for: model.subject)
        if !reviews.isEmpty {
          Section {
            ForEach(reviews) { item in
              LabeledContent(item.skill) {
                Text(item.due <= .now ? "Next exam" : item.due.formatted(.relative(presentation: .named)))
              }
            }
            .onDelete { offsets in model.study.deleteReviews(Set(offsets.map { reviews[$0].id })) }
          } header: {
            Text("To review")
          } footer: {
            Text("Skills you got wrong in a Check. Each one is in your next exam, then comes back after 3, 7 and 14 days.")
          }
        }
      }
      .navigationTitle("Practice")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Button("Done") { dismiss() }
      }
      .fullScreenCover(isPresented: $showExam) {
        WrittenAnswerScreen(answer: model.study.exam?.exam ?? "", printTitle: "\(model.subject.name) practice exam")
      }
      .fullScreenCover(isPresented: $showKey) {
        WrittenAnswerScreen(answer: model.study.exam?.key ?? "")
      }
    }
  }

  @ViewBuilder
  private func examSection(_ exam: PracticeExam) -> some View {
    let subject = ClaudeClient.Subject(rawValue: exam.subject)?.name ?? ""
    Section {
      Button(exam.handedIn == nil ? "Show and print exam" : "Show exam", systemImage: "printer") { showExam = true }
      if exam.handedIn != nil {
        Button("Hear worked solutions", systemImage: "speaker.wave.2") {
          model.hearSolutions()
          dismiss()
        }
        Button("Show worked solutions", systemImage: "function") { showKey = true }
      }
    } header: {
      Text("\(subject) exam, \(exam.created.formatted(date: .abbreviated, time: .shortened))")
    } footer: {
      Text(Self.examFooter(handedIn: exam.handedIn != nil))
    }
  }

  private static func examFooter(handedIn: Bool) -> String {
    if handedIn {
      return "Marked. Photos in Check are marked against the key. The solutions are dictated like any answer, "
        + "and a photo of your work right after is checked and continued."
    }
    return "Print it and take it like the real one, phone away. Photos are set to Check, so when you're done, "
      + "a capture press hands it in and marks your paper against the key. The key stays locked until then."
  }

  private var newExamFooter: String {
    if model.testMode { return "Turn off Test mode to write an exam: it needs Claude." }
    if !model.hasAPIKey { return "Add your Anthropic API key in Settings first." }
    let due = model.study.due(for: model.subject).count
    let review = due == 0 ? "" : " \(due) skill\(due == 1 ? "" : "s") to review will be worked in."
    let replaces = model.study.exam == nil ? "" : " It replaces the exam above."
    return "Like your real tests, with new numbers. Takes a minute or two.\(review)\(replaces)"
  }
}
