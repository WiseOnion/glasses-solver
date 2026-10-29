import AVFoundation
import SwiftUI
import UIKit

/// The app's look: quiet. System colors on near-black, white and gray text, and the system
/// blue only where something can be tapped or is selected.
enum Theme {
  static let accent = Color.blue
  static let connected = Color(.systemGreen)
  static let secondary = Color.secondary
}

extension ClaudeClient.Subject {
  /// The subject as the app shows it.
  var title: String { self == .math ? "Math 131" : "Chemistry" }
  var symbol: String { self == .math ? "function" : "flask.fill" }
}

extension View {
  /// Liquid Glass for a floating control on iOS 26, the closest standard material before it.
  @ViewBuilder
  func glassControl<S: Shape>(in shape: S) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: shape)
    } else {
      background(.ultraThinMaterial, in: shape)
    }
  }
}

/// Three places: Solve, History, Settings. The answer opens over all of them for each new
/// photo, so what the glasses say is on the screen too.
struct ContentView: View {
  @Bindable var model: AppModel
  @State private var tab: Tab
  @State private var showWorkspace = false

  init(model: AppModel, tab: Tab = .solve) {
    self.model = model
    _tab = State(initialValue: tab)
  }

  enum Tab: Hashable {
    case solve, history, settings
  }

  var body: some View {
    TabView(selection: $tab) {
      SolveView(model: model, openWorkspace: { showWorkspace = true })
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

/// Solve: a quiet companion to the glasses. A line of status at the top, the subject, and in
/// the middle the current state with one small capture control. Nothing else competes; the
/// glasses do the work, and the answer screen is where the app becomes the focus.
struct SolveView: View {
  @Bindable var model: AppModel
  let openWorkspace: () -> Void
  @State private var showStartSession = false
  @State private var showSession = false

  private var connected: Bool { model.isRegistered && model.hasActiveDevice }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        status
          .padding(.top, 4)
        if model.isRegistered {
          SubjectSelector(subject: $model.subject)
            .disabled(model.isBusy)
            .padding(.top, 18)
        }
        if model.isRegistered {
          Spacer()
          center
            .frame(maxWidth: .infinity)
          Spacer()
          bottom
        } else {
          setup
        }
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 8)
      .background(Color(.systemBackground))
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(isPresented: $showSession) { SessionControlsView(model: model) }
      .sheet(isPresented: $showStartSession) { StartSessionView(model: model) }
    }
  }

  // MARK: - Status: one quiet line

  private var status: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(connected ? Color(.systemGreen) : Color(.systemGray2))
        .frame(width: 6, height: 6)
      Text("Ray-Ban Meta")
        .foregroundStyle(.primary)
      Text(statusText)
        .foregroundStyle(.secondary)
      if model.testMode {
        Text("· Test Mode")
          .foregroundStyle(.secondary)
      }
    }
    .font(.footnote)
    .accessibilityElement(children: .combine)
  }

  private var statusText: String {
    if !model.isRegistered { return model.registrationState == .registering ? "Connecting…" : "Not connected" }
    if model.sessionActive { return model.sessionPaused ? "Paused" : "Hands-free" }
    return model.hasActiveDevice ? "Connected" : "Asleep"
  }

  // MARK: - Center: the state, then one small control

  private var center: some View {
    VStack(spacing: 6) {
      Text(stateTitle)
        .font(.title2.weight(.semibold))
        .contentTransition(.opacity)
      if let detail {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      control
        .padding(.top, 28)
    }
    .animation(.easeOut(duration: 0.2), value: stateTitle)
  }

  private var stateTitle: String {
    guard model.isRegistered else { return "Not Connected" }
    switch model.phase {
    case .capturing: return "Taking Photo"
    case .thinking: return "Solving"
    case .idle: return model.hasActiveDevice || model.sessionActive ? "Ready" : "Glasses Asleep"
    }
  }

  /// Only what helps right now: what to look at, or what's in the way.
  private var detail: String? {
    if !model.isRegistered {
      return model.registrationState == .registering ? "Finish in the Meta AI app." : "Connect your Ray-Ban Meta glasses."
    }
    if !model.canSolve { return "Add your API key in Settings." }
    if !model.hasActiveDevice { return "Unfold your glasses to wake them." }
    if model.phase == .thinking { return "Tap again to use a new photo." }
    if model.phase == .capturing { return nil }
    return model.subject == .math ? "Look at a problem" : "Look at the page"
  }

  private var control: some View {
    Button {
      Task { await model.solve() }
    } label: {
      ZStack {
        Circle()
          .fill(Color(.tertiarySystemFill))
        Circle()
          .strokeBorder(Color(.separator), lineWidth: 1)
        if model.phase != .idle {
          ProgressView()
        } else {
          Image(systemName: "camera")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(solveEnabled ? Color.primary : Color.secondary)
        }
      }
      .frame(width: 68, height: 68)
    }
    .buttonStyle(PressScaleStyle(scale: 0.92))
    .disabled(!solveEnabled)
    .accessibilityLabel("Solve")
    .accessibilityHint("Takes a photo with your glasses and solves it")
  }

  // MARK: - Setup: before the glasses are connected (after Meta's CameraAccess sample)

  private var setup: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer()
      Text("Solve with your glasses")
        .font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 20) {
        GlassesTip(symbol: "camera", title: "Press capture", text: "Your glasses take a photo and say the answer.")
        GlassesTip(symbol: "hand.tap", title: "Double-tap the touchpad", text: "Hear how to get there.")
        GlassesTip(symbol: "checkmark.circle", title: "Double-press capture", text: "Check an answer or your own work.")
      }
      .padding(.top, 28)
      Spacer()
      Text("The Meta AI app opens to confirm the connection.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
      Button {
        model.connectGlasses()
      } label: {
        Text(model.registrationState == .registering ? "Connecting…" : "Connect Glasses")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(model.registrationState == .registering)
      .padding(.top, 12)
    }
  }

  private var solveEnabled: Bool { model.canStartPhoto && model.isRegistered && model.canSolve }

  // MARK: - Bottom: secondary, small

  @ViewBuilder
  private var bottom: some View {
    if model.isRegistered {
      VStack(spacing: 0) {
        if model.speechHeld {
          HStack {
            Label("Glasses audio disconnected", systemImage: "speaker.slash")
              .font(.footnote)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Play Here") { model.playOnPhone() }
              .font(.footnote)
          }
          .padding(.vertical, 10)
          Divider()
        }
        if let result = latest {
          Button(action: openWorkspace) {
            HStack(spacing: 12) {
              if let photo = model.lastPhoto {
                Image(uiImage: photo)
                  .resizable()
                  .scaledToFill()
                  .frame(width: 34, height: 34)
                  .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                  .accessibilityHidden(true)
              }
              VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(result.text)
                  .font(.subheadline)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens the answer")
          Divider()
        }
        HStack {
          Button {
            if model.sessionActive { showSession = true } else { showStartSession = true }
          } label: {
            Label(
              model.sessionActive ? "Hands-Free On" : "Hands-Free",
              systemImage: "eyeglasses")
          }
          .disabled(!model.sessionActive && (model.isStartingSession || model.isBusy || !model.canSolve))
          Spacer()
          if model.subject == .chemistry {
            Button("Check Sheet") { Task { await model.checkAnswerSheet() } }
              .disabled(!solveEnabled)
          }
        }
        .font(.subheadline)
        .tint(.secondary)
        .frame(minHeight: 44)
      }
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

/// One thing the glasses do, for the setup screen.
struct GlassesTip: View {
  let symbol: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Math 131 / Chemistry, as two quiet words: only the selected one gets a soft highlight.
struct SubjectSelector: View {
  @Binding var subject: ClaudeClient.Subject

  var body: some View {
    HStack(spacing: 4) {
      ForEach(ClaudeClient.Subject.allCases, id: \.self) { option in
        Button {
          subject = option
        } label: {
          Text(option.title)
            .font(.subheadline.weight(option == subject ? .semibold : .regular))
            .foregroundStyle(option == subject ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
              if option == subject {
                Capsule().fill(Color(.tertiarySystemFill))
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(option == subject ? .isSelected : [])
      }
    }
    .animation(.easeOut(duration: 0.15), value: subject)
  }
}

/// A custom button's pressed state (Apple: "Always include a press state for a custom button").
struct PressScaleStyle: ButtonStyle {
  var scale: CGFloat = 0.94

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? scale : 1)
      .brightness(configuration.isPressed ? -0.06 : 0)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

/// What the glasses' controls do in the current subject, and ending the session.
struct SessionControlsView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section {
        LabeledContent(model.subject.title, value: model.sessionPaused ? "Paused" : "Active")
        if let problem = buttonProblem {
          Text(problem)
            .font(.footnote)
            .foregroundStyle(.secondary)
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
    .listStyle(.grouped)
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
        Row(symbol: "checkmark.circle", control: "Double Press", action: "Check"),
        Row(symbol: "arrow.counterclockwise", control: "Hold", action: "Repeat"),
        Row(symbol: "hand.draw", control: "Swipe", action: "Previous / Next"),
        Row(symbol: "pause.circle", control: "Tap", action: "Pause / Resume"),
        Row(symbol: "xmark.circle", control: "Touch and Hold", action: "End Session"),
      ]
      : [
        Row(symbol: "camera", control: "Capture", action: "Solve Page"),
        Row(symbol: "hand.tap", control: "Double Tap", action: "Repeat"),
        Row(symbol: "checkmark.circle", control: "Double Press", action: "Check Answer Sheet"),
        Row(symbol: "hand.draw", control: "Swipe", action: "Replay Previous / Next"),
        Row(symbol: "pause.circle", control: "Tap", action: "Pause / Resume"),
        Row(symbol: "xmark.circle", control: "Touch and Hold", action: "End Session"),
      ]
  }

  var body: some View {
    ForEach(rows, id: \.self) { row in
      Label {
        LabeledContent(row.control, value: row.action)
      } icon: {
        Image(systemName: row.symbol)
          .foregroundStyle(.secondary)
      }
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
          Button("Back", systemImage: "chevron.left") { dismiss() }
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
      List {
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

        Section("Speaking") {
          NavigationLink {
            VoiceSettingsView(model: model)
          } label: {
            LabeledContent("Voice", value: model.voiceEngine.shortName)
          }
          NavigationLink("Writing Pauses") { WritingSettingsView(model: model) }
        }

        Section {
          NavigationLink("Advanced") { AdvancedSettingsView(model: model) }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
    }
    .listStyle(.grouped)
    .listSectionSpacing(.compact)
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
    List {
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
    List {
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
    List {
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
    List {
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
      List {
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
    .listStyle(.grouped)
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
