import AVFoundation
import SwiftUI
import UIKit

/// The app's look: near-black, white text, muted gray, one restrained accent (iOS blue).
enum Theme {
  static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
  static let surface = Color(white: 0.1)
  static let secondary = Color(white: 0.6)
  static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
  static let connected = Color(red: 0.2, green: 0.78, blue: 0.35)
}

extension ClaudeClient.Subject {
  /// The subject as the app shows it.
  var title: String { self == .math ? "Math 131" : "Chemistry" }
  var symbol: String { self == .math ? "function" : "flask" }
}

/// Three places: Solve, History, Settings. The written answer opens over all of them for each
/// new photo, so what the glasses say is on the screen too.
struct ContentView: View {
  @Bindable var model: AppModel
  @State private var tab = Tab.solve
  @State private var showWorkspace = false

  enum Tab: Hashable {
    case solve, history, settings
  }

  var body: some View {
    TabView(selection: $tab) {
      SolveView(model: model, openSettings: { tab = .settings }, openWorkspace: { showWorkspace = true })
        .tabItem { Label("Solve", systemImage: "viewfinder") }
        .tag(Tab.solve)
      HistoryView(model: model)
        .tabItem { Label("History", systemImage: "clock") }
        .tag(Tab.history)
      SettingsView(model: model)
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(Tab.settings)
    }
    .preferredColorScheme(.dark)
    .tint(Theme.accent)
    .fullScreenCover(isPresented: $showWorkspace) { WrittenAnswerScreen(model: model) }
    .onChange(of: model.photosStarted) { showWorkspace = true }
    .alert("Allow camera access?", isPresented: $model.showCameraPermissionPrompt) {
      Button("Cancel", role: .cancel) { model.cancelCameraPermission() }
      Button("Allow") { Task { await model.confirmCameraPermission() } }
    } message: {
      Text("Glasses Solver needs your glasses' camera to capture photos. Meta AI opens to allow it.")
    }
    .alert(
      "Something went wrong",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Copy Log") { UIPasteboard.general.string = DiagnosticsLog.shared.text }
    } message: {
      Text(Self.shortError(model.errorMessage))
    }
  }

  /// The first paragraph of an error: the details stay in the log.
  static func shortError(_ message: String?) -> String {
    guard let message else { return "" }
    return message.components(separatedBy: "\n\n").first ?? message
  }
}

/// Solve: connection, subject, and one dominant action.
struct SolveView: View {
  @Bindable var model: AppModel
  let openSettings: () -> Void
  let openWorkspace: () -> Void
  @State private var showStartSession = false

  private var connected: Bool { model.isRegistered && model.hasActiveDevice }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if model.isRegistered {
            connectedContent
          } else {
            disconnectedContent
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
      .background(Theme.background.ignoresSafeArea())
      .navigationTitle("Glasses Solver")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Settings", systemImage: "gearshape", action: openSettings)
        }
      }
      .navigationDestination(for: String.self) { _ in SessionControlsView(model: model) }
      .sheet(isPresented: $showStartSession) { StartSessionView(model: model) }
    }
  }

  // MARK: - Not connected

  private var disconnectedContent: some View {
    VStack(spacing: 16) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 64, weight: .light))
        .foregroundStyle(.white)
        .padding(.top, 72)
        .accessibilityHidden(true)
      Text("Connect your glasses")
        .font(.title2.weight(.semibold))
      Text(
        model.registrationState == .registering
          ? "Finish connecting in the Meta AI app." : "Tap below to connect your Ray-Ban Meta glasses.")
        .font(.subheadline)
        .foregroundStyle(Theme.secondary)
        .multilineTextAlignment(.center)
      Button {
        model.connectGlasses()
      } label: {
        Text(model.registrationState == .registering ? "Connecting…" : "Connect Glasses")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 54)
          .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
      }
      .buttonStyle(.plain)
      .disabled(model.registrationState == .registering)
      .padding(.top, 24)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Connected

  private var connectedContent: some View {
    VStack(alignment: .leading, spacing: 20) {
      connectionCard
      subjectMenu
      if model.sessionActive {
        NavigationLink(value: "session") {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(model.subject.title)
                .font(.body)
              Text(model.sessionPaused ? "Session Paused" : "Session Active")
                .font(.subheadline)
                .foregroundStyle(model.sessionPaused ? Color.orange : Theme.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(Theme.secondary)
          }
          .padding(16)
          .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the glasses controls and ends the session")
      }
      solveButton
        .padding(.top, 12)
      if model.subject == .chemistry {
        Picker("A photo", selection: $model.photoAction) {
          ForEach(ClaudeClient.PhotoAction.allCases, id: \.self) { Text($0.name).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(model.isBusy)
      }
      Text(hint)
        .font(.footnote)
        .foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
      if model.speechHeld { audioHeld }
      latestResult
      if !model.sessionActive {
        Button {
          showStartSession = true
        } label: {
          Group {
            if model.isStartingSession {
              ProgressView()
            } else {
              Label("Start Hands-Free Session", systemImage: "eyeglasses")
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isStartingSession || model.isBusy || !model.canSolve)
      }
    }
  }

  private var connectionCard: some View {
    HStack(spacing: 14) {
      Image(systemName: "eyeglasses")
        .font(.title3)
        .frame(width: 44, height: 44)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text("Ray-Ban Meta")
          .font(.body.weight(.medium))
        HStack(spacing: 6) {
          Circle()
            .fill(connected ? Theme.connected : Color(white: 0.4))
            .frame(width: 7, height: 7)
          Text(connected ? "Connected" : "Put on your glasses")
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
        }
      }
      Spacer()
    }
    .padding(14)
    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }

  private var subjectMenu: some View {
    Menu {
      Picker("Subject", selection: $model.subject) {
        ForEach(ClaudeClient.Subject.allCases, id: \.self) { Text($0.title).tag($0) }
      }
    } label: {
      HStack(spacing: 6) {
        Text("\(model.subject.title) · \(stateWord)")
          .font(.title3.weight(.semibold))
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Theme.secondary)
      }
      .foregroundStyle(.white)
    }
    .disabled(model.isBusy)
    .accessibilityLabel("Subject, \(model.subject.title)")
  }

  private var stateWord: String {
    switch model.phase {
    case .capturing: "Taking Photo"
    case .thinking: "Solving"
    case .idle: "Ready"
    }
  }

  private var solveButton: some View {
    Button {
      Task { await model.solve() }
    } label: {
      HStack(spacing: 10) {
        if model.phase != .idle { ProgressView().tint(.white) }
        Text(solveLabel)
      }
      .font(.title3.weight(.semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 58)
      .background(Theme.accent.opacity(solveEnabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .disabled(!solveEnabled)
  }

  private var solveEnabled: Bool { model.canStartPhoto && model.isRegistered && model.canSolve }

  private var solveLabel: String {
    switch model.phase {
    case .capturing: "Taking Photo…"
    case .thinking: "Solving…"
    case .idle: model.subject == .chemistry && model.photoAction == .check ? "Check" : "Solve"
    }
  }

  private var hint: String {
    var text: String
    if !model.canSolve {
      text = "Add your API key in Settings → Advanced."
    } else if !model.hasActiveDevice {
      text = "Unfold your glasses and put them on."
    } else if model.phase == .thinking {
      text = "Tap again to replace this photo with a new one."
    } else if model.sessionActive {
      text = "Press capture on your glasses, or tap Solve."
    } else {
      text = "Look at the problem, then tap Solve."
    }
    if model.testMode { text += "\nTest Mode" }
    return text
  }

  private var audioHeld: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Glasses audio disconnected", systemImage: "speaker.slash")
        .font(.subheadline.weight(.semibold))
      Text("Speech is paused so it doesn't play out loud. It continues when the glasses reconnect.")
        .font(.footnote)
        .foregroundStyle(Theme.secondary)
      HStack {
        Button("Play on iPhone") { model.playOnPhone() }
        Spacer()
        Button("Stop") { model.stopSpeaking() }
      }
      .font(.subheadline)
    }
    .padding(16)
    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
  }

  /// The answer being worked on, one row: tap to open it.
  @ViewBuilder
  private var latestResult: some View {
    if let result = latest {
      Button(action: openWorkspace) {
        HStack(spacing: 14) {
          if let photo = model.lastPhoto {
            Image(uiImage: photo)
              .resizable()
              .scaledToFill()
              .frame(width: 48, height: 48)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(result.title)
              .font(.caption)
              .foregroundStyle(Theme.secondary)
            Text(result.text)
              .foregroundStyle(.white)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens the answer")
    }
  }

  private var latest: (title: String, text: String)? {
    if model.subject == .math {
      guard let current = model.currentProblem else { return nil }
      let answer = current.problem?.answer ?? ""
      return ("Problem \(current.label)", answer.isEmpty ? "Solving…" : answer)
    }
    let questions = AppModel.questions(in: model.lastAnswer)
    guard !questions.isEmpty else { return nil }
    let names = questions.map(\.label).prefix(6).joined(separator: ", ")
    return ("Last page", questions.count == 1 ? "Question \(names)" : "Questions \(names)")
  }
}

/// What the glasses' controls do in the current subject, and ending the session.
struct SessionControlsView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section {
        Text(model.subject.title)
          .font(.title2.weight(.semibold))
        if let problem = buttonProblem {
          Text(problem)
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
        }
      }
      Section("Glasses Controls") {
        GlassesControlsList(subject: model.subject)
      }
      if model.subject == .chemistry {
        Section {
          NavigationLink("Session Prompt") {
            ScrollView {
              Text(model.sessionPrompt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Session Prompt")
            .navigationBarTitleDisplayMode(.inline)
          }
        }
      }
      Section {
        Button("End Session", role: .destructive) {
          model.stopSession()
          dismiss()
        }
      }
    }
    .navigationTitle("Session")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var buttonProblem: String? {
    switch model.shutterStatus {
    case .active: model.sessionPaused ? "Paused. Tap the touchpad once to resume." : nil
    case .off, .activating: "Connecting to the glasses' buttons…"
    case .unavailable: "The glasses' buttons aren't available. Solve on the iPhone still works."
    }
  }
}

/// Each glasses control and what it does, for the subject.
struct GlassesControlsList: View {
  let subject: ClaudeClient.Subject

  private struct Row: Hashable {
    let symbol: String
    let control: String
    let action: String
  }

  private var rows: [Row] {
    subject == .math
      ? [
        Row(symbol: "camera", control: "Capture", action: "Solve"),
        Row(symbol: "hand.tap", control: "Double Tap", action: "Explain"),
        Row(symbol: "checkmark.seal", control: "Double Press", action: "Check"),
        Row(symbol: "arrow.counterclockwise", control: "Hold", action: "Repeat"),
        Row(symbol: "hand.draw", control: "Swipe", action: "Previous / Next"),
        Row(symbol: "pause.circle", control: "Tap", action: "Pause / Resume"),
        Row(symbol: "xmark.circle", control: "Touch and Hold", action: "End Session"),
      ]
      : [
        Row(symbol: "camera", control: "Capture", action: "Solve Page"),
        Row(symbol: "hand.tap", control: "Double Tap", action: "Repeat"),
        Row(symbol: "checkmark.seal", control: "Double Press", action: "Check Answer Sheet"),
        Row(symbol: "hand.draw", control: "Swipe", action: "Replay Previous / Next"),
        Row(symbol: "pause.circle", control: "Tap", action: "Pause / Resume"),
        Row(symbol: "xmark.circle", control: "Touch and Hold", action: "End Session"),
      ]
  }

  var body: some View {
    ForEach(rows, id: \.self) { row in
      HStack(spacing: 14) {
        Image(systemName: row.symbol)
          .font(.body)
          .frame(width: 28)
          .foregroundStyle(Theme.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(row.control)
          Text(row.action)
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
        }
      }
      .padding(.vertical, 2)
      .accessibilityElement(children: .combine)
    }
  }
}

/// A photo, full screen.
struct PhotoDetailView: View {
  let image: UIImage?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Photo from the glasses")
        } else {
          ContentUnavailableView("Photo not found", systemImage: "photo")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.ignoresSafeArea())
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Label("Back", systemImage: "chevron.left")
              .labelStyle(.titleAndIcon)
          }
        }
      }
    }
    .preferredColorScheme(.dark)
  }
}

/// Settings in a few groups, each showing its current value; details one level down, and the
/// technical controls under Advanced (Nielsen Norman Group on progressive disclosure).
struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    NavigationStack {
      Form {
        Section("General") {
          Picker("Subject", selection: $model.subject) {
            ForEach(ClaudeClient.Subject.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.navigationLink)
        }

        Section {
          Toggle("Fast Answers", isOn: $model.fastAnswers)
          Toggle("Sharper Photos", isOn: $model.useHighResPhoto)
        } header: {
          Text("Solving")
        } footer: {
          Text("Fast Answers start sooner and cost more. Sharper Photos read small print better but take longer.")
        }

        Section("Voice") {
          NavigationLink {
            VoiceSettingsView(model: model)
          } label: {
            LabeledContent("Voice", value: model.voiceEngine.shortName)
          }
        }

        Section("Writing") {
          NavigationLink("Writing Pauses") { WritingSettingsView(model: model) }
        }

        Section {
          NavigationLink("Advanced") { AdvancedSettingsView(model: model) }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/// Which voice reads answers, and the tools for choosing one by ear.
private struct VoiceSettingsView: View {
  @Bindable var model: AppModel
  @State private var azureKeyDraft = ""
  /// Re-read when this opens, so newly downloaded voices show up.
  @State private var voices: [(id: String, label: String)] = []
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading) {
          LabeledContent("Speaking Speed", value: String(format: "%.1f×", model.speechRate / Speaker.defaultRate))
          Slider(value: $model.speechRate, in: Speaker.rateRange) {
            Text("Speaking Speed")
          } minimumValueLabel: {
            Image(systemName: "tortoise")
          } maximumValueLabel: {
            Image(systemName: "hare")
          }
        }
        Button("Preview Voice", systemImage: "play.circle") { model.previewVoice() }
        Button("Compare Voices", systemImage: "person.2.wave.2") { model.compareVoices() }
        Button("Test Voice", systemImage: "speaker.wave.2") { model.testVoice() }
      }

      Section {
        Picker("Voice", selection: $model.voiceEngine) {
          Text("Azure (online, clearest)").tag(AppModel.VoiceEngine.azure)
          if model.hasNeuralVoice {
            Text("Heart (built in, offline)").tag(AppModel.VoiceEngine.heart)
          }
          Text("Apple").tag(AppModel.VoiceEngine.apple)
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("Voice Selection")
      } footer: {
        Text("Using \(model.voiceDescription).")
      }

      if model.voiceEngine == .azure {
        Section {
          Picker("Azure voice", selection: $model.azureVoiceName) {
            ForEach(AppModel.azureVoices, id: \.self) { id in
              Text(Speaker.azureVoiceName(id)).tag(id)
            }
          }
          TextField("Region, such as eastus", text: $model.azureRegion)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField(model.hasAzureKey ? "Azure key saved" : "Azure Speech key", text: $azureKeyDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Save Azure key") {
            model.saveAzureKey(azureKeyDraft)
            azureKeyDraft = ""
          }
          .disabled(azureKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
          if model.hasAzureKey {
            Button("Delete Azure key", role: .destructive) { model.deleteAzureKey() }
          }
        } header: {
          Text("Azure")
        } footer: {
          Text(
            "Needs internet and your own free key: portal.azure.com, a Speech resource on the Free F0 tier. "
              + "Heart is used when Azure can't be reached.")
        }
      }

      if model.voiceEngine == .apple {
        Section {
          Picker("Apple voice", selection: $model.voiceIdentifier) {
            Text("Automatic (best installed)").tag(String?.none)
            // Keep a saved voice in the list even when iOS isn't offering it right now, so
            // the choice isn't lost and you can see it's still selected.
            if let saved = model.voiceIdentifier, !voices.contains(where: { $0.id == saved }) {
              Text("Your saved voice (not available right now)").tag(String?.some(saved))
            }
            ForEach(voices, id: \.id) { voice in
              Text(voice.label).tag(String?.some(voice.id))
            }
          }
        } footer: {
          Text(
            "Premium voices sound far more natural. Download them in iOS Settings → Accessibility → "
              + "Read & Speak → Voices → English.")
        }
      }

      Section {
        Button("Match Speed", systemImage: "gauge.with.needle") { model.matchSpeed() }
        Button("Reset Speed") { model.speechRate = Speaker.defaultRate }
          .disabled(model.speechRate == Speaker.defaultRate)
      } footer: {
        Text("Match Speed sets the voice to about 150 words a minute.")
      }
    }
    .navigationTitle("Voice")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      voices = model.availableVoices
      model.logInstalledVoices()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { voices = model.availableVoices }
    }
    // Apple's recommended signal: voices downloaded (in Settings or apps like Piper) or deleted.
    .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
      voices = model.availableVoices
      model.logInstalledVoices()
    }
  }
}

/// How long math dictation waits while you write.
private struct WritingSettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading) {
          LabeledContent("Time per Line", value: String(format: "%.1f×", model.writingTime))
          Slider(value: $model.writingTime, in: Speaker.writingTimeRange) {
            Text("Time per Line")
          } minimumValueLabel: {
            Text("Less").font(.caption)
          } maximumValueLabel: {
            Text("More").font(.caption)
          }
        }
        Toggle("Pause Between Parts", isOn: $model.dictateInParts)
        Button("Reset") { model.writingTime = 1 }
          .disabled(model.writingTime == 1)
      } footer: {
        Text("When a line is read aloud for you to copy, these set how long it waits while you write.")
      }

      // The practice answer is calculus; chemistry's Test voice already has a worked part.
      if model.subject == .math {
        Section {
          Button("Test Limit Definition", systemImage: "function") { model.testLimitDefinition() }
        } footer: {
          Text("A long worked answer (about 7 minutes) to practice copying.")
        }
      }
    }
    .navigationTitle("Writing Pauses")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct APIKeySettingsView: View {
  @Bindable var model: AppModel
  @State private var keyDraft = ""

  var body: some View {
    Form {
      Section {
        SecureField("sk-ant-…", text: $keyDraft)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Save key") {
          model.saveAPIKey(keyDraft)
          keyDraft = ""
        }
        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        if model.hasAPIKey {
          Button("Delete saved key", role: .destructive) { model.deleteAPIKey() }
        }
      } footer: {
        Text(model.hasAPIKey ? "A key is saved in the Keychain on this phone." : "No key saved yet.")
      }
    }
    .navigationTitle("Anthropic API Key")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Rarely changed controls, then the developer tools and diagnostics.
private struct AdvancedSettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section {
        Toggle("Reverse Swipe Direction", isOn: $model.reverseSwipes)
        if model.isRegistered {
          Button("Disconnect Glasses", role: .destructive) { model.disconnectGlasses() }
        }
      } header: {
        Text("Glasses")
      } footer: {
        Text("Turn on Reverse Swipe Direction if swiping on the glasses moves the wrong way.")
      }

      Section {
        NavigationLink {
          APIKeySettingsView(model: model)
        } label: {
          LabeledContent("Anthropic API Key") {
            Text(model.hasAPIKey ? "Saved" : "Not Set")
              .foregroundStyle(model.hasAPIKey ? Theme.secondary : Color.red)
          }
        }
        Toggle("Test Mode", isOn: $model.testMode)
      } header: {
        Text("Developer")
      } footer: {
        Text("Test Mode runs the glasses, photo and voice but skips Claude, and plays a sample answer. It's free.")
      }

      Section("Diagnostics") {
        NavigationLink("Diagnostics") { DiagnosticsView() }
      }
    }
    .navigationTitle("Advanced")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct StartSessionView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var prompt = ""

  private var trimmedPrompt: String {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          GlassesControlsList(subject: model.subject)
        } header: {
          Text("Glasses Controls")
        } footer: {
          Text("You can lock your iPhone. The glasses keep working.")
        }

        // Math runs on the buttons alone; chemistry still sends an editable prompt.
        if model.subject == .chemistry {
          Section {
            TextField("Prompt", text: $prompt, axis: .vertical)
              .lineLimit(3...10)
            if prompt != model.subject.defaultPrompt {
              Button("Reset to Default") { prompt = model.subject.defaultPrompt }
            }
          } header: {
            Text("Prompt")
          } footer: {
            Text("Sent with every page you photograph.")
          }
        }
      }
      .navigationTitle(model.subject.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Start") {
            let prompt = model.subject == .chemistry ? trimmedPrompt : model.subject.defaultPrompt
            // Dismiss first so a camera-permission alert can appear on the main screen.
            dismiss()
            Task { await model.startSession(prompt: prompt) }
          }
          .disabled(model.subject == .chemistry && trimmedPrompt.isEmpty)
        }
      }
      .onAppear { if prompt.isEmpty { prompt = model.subject.defaultPrompt } }
    }
    .preferredColorScheme(.dark)
  }
}

struct DiagnosticsView: View {
  private let log = DiagnosticsLog.shared
  @State private var sdkLogFiles: [URL] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if sdkLogFiles.isEmpty {
          Text("No Meta SDK log files yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          // The SDK's own log has link and authentication details the app never sees.
          ShareLink(items: sdkLogFiles) {
            Label("Share Meta SDK log (\(sdkLogFiles.count) file\(sdkLogFiles.count == 1 ? "" : "s"))",
              systemImage: "square.and.arrow.up")
          }
          .buttonStyle(.bordered)
        }
        Text(log.lines.isEmpty && log.previousRun.isEmpty ? "Nothing logged yet." : log.text)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding()
    }
    .defaultScrollAnchor(.bottom)
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { sdkLogFiles = Self.findSDKLogFiles() }
    .toolbar {
      ToolbarItemGroup(placement: .bottomBar) {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = log.text }
          .labelStyle(.titleAndIcon)
        Spacer()
          .disabled(log.lines.isEmpty)
        Button("Clear", systemImage: "trash") { log.clear() }
          .labelStyle(.titleAndIcon)
          .disabled(log.lines.isEmpty)
      }
    }
  }

  /// The SDK writes to Library/Caches/MetaWearablesDAT/Logs inside the app's container.
  private static func findSDKLogFiles() -> [URL] {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return []
    }
    let folder = caches.appending(path: "MetaWearablesDAT/Logs", directoryHint: .isDirectory)
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}
