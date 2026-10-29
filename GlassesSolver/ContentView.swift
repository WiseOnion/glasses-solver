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
      SolveView(model: model, openWorkspace: { showWorkspace = true }, openSettings: { tab = .settings })
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

/// Solve: a companion to the glasses, which do the work. Built from two references:
/// - Meta's CameraAccess sample: the root follows registration (setup until the glasses are
///   linked), and each state gets one title, one line on what to do, and at most one action,
///   picked by a priority-ordered ladder.
/// - Apple's samples (Food Truck, Backyard Birds): native navigation, a segmented picker for
///   two modes, ContentUnavailableView for the state, a hairline thumbnail row.
///
/// "Connected" means one thing here: the app is holding a glasses session (Connect starts it,
/// Disconnect ends it). Until then the glasses work with Meta AI as usual, even though the app
/// is linked to them and can see them.
struct SolveView: View {
  @Bindable var model: AppModel
  let openWorkspace: () -> Void
  let openSettings: () -> Void
  @State private var showSession = false

  var body: some View {
    NavigationStack {
      Group {
        if model.isRegistered {
          linked
        } else {
          setup
        }
      }
      .navigationTitle("Solve")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.isRegistered {
          ToolbarItem(placement: .principal) {
            Picker("Subject", selection: $model.subject) {
              ForEach(ClaudeClient.Subject.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.isBusy)
          }
        }
        if model.sessionActive {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button("Glasses Controls", systemImage: "list.bullet") { showSession = true }
              Button("Disconnect", systemImage: "xmark", role: .destructive) { model.stopSession() }
            } label: {
              Label("Glasses", image: "Glasses")
            }
          }
        }
      }
      .navigationDestination(isPresented: $showSession) { SessionControlsView(model: model) }
    }
  }

  // MARK: - Linked: the state, what to do, one action

  private var linked: some View {
    VStack(spacing: 0) {
      status
        .padding(.top, 8)
      ContentUnavailableView {
        Label {
          Text(state.title)
        } icon: {
          if model.phase != .idle || model.isStartingSession {
            ProgressView()
              .controlSize(.large)
              .tint(.secondary)
          } else if state.symbol == "Glasses" {
            // A custom image doesn't scale with the font like a symbol: size it to match.
            Image("Glasses")
              .resizable()
              .scaledToFit()
              .frame(width: 64, height: 44)
          } else {
            Image(systemName: state.symbol)
          }
        }
      } description: {
        Text(state.detail)
      } actions: {
        actions
      }
      .animation(.easeOut(duration: 0.2), value: state.title)
      bottom
    }
  }

  @ViewBuilder
  private var actions: some View {
    if !model.canSolve {
      Button("Open Settings", action: openSettings)
        .buttonStyle(.bordered)
    } else if !model.sessionActive {
      if !model.isStartingSession {
        Button("Connect Glasses") { Task { await model.connect() } }
          .buttonStyle(.borderedProminent)
          .disabled(!model.hasActiveDevice)
      }
    } else if model.phase == .idle && !model.sessionPaused {
      Button("Take Photo") { Task { await model.solve() } }
        .buttonStyle(.bordered)
        .disabled(!model.canStartPhoto)
      if model.subject == .chemistry {
        Button("Check Answer Sheet") { Task { await model.checkAnswerSheet() } }
          .disabled(!model.canStartPhoto)
      }
    }
  }

  /// One small line: the glasses, and whether the app is connected to them.
  private var status: some View {
    HStack(spacing: 6) {
      Image("Glasses")
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
        .foregroundStyle(.secondary)
      Text("Ray-Ban Meta")
      Circle()
        .fill(model.sessionActive && !model.sessionPaused ? Color(.systemGreen) : Color(.systemGray))
        .frame(width: 6, height: 6)
      Text(statusText)
        .foregroundStyle(.secondary)
    }
    .font(.footnote)
    .accessibilityElement(children: .combine)
  }

  private var statusText: String {
    var text: String
    if model.sessionActive {
      text = model.sessionPaused ? "Paused" : "Connected"
    } else {
      text = model.isStartingSession ? "Connecting…" : "Not connected"
    }
    if model.testMode { text += " · Test Mode" }
    return text
  }

  /// The one thing that matters now, highest priority first.
  private var state: (title: String, detail: String, symbol: String) {
    let page = model.subject == .math ? "a problem" : "the page"
    if !model.canSolve { return ("Add Your API Key", "Solving needs a Claude API key.", "key") }
    switch model.phase {
    case .capturing: return ("Taking Photo", "Hold still.", "camera")
    case .thinking:
      return ("Solving", model.sessionActive ? "Press capture again to use a new photo." : "This takes a few seconds.", "camera")
    case .idle: break
    }
    if model.isStartingSession { return ("Connecting", "Getting your glasses ready.", "Glasses") }
    if !model.sessionActive {
      if !model.hasActiveDevice { return ("Glasses Asleep", "Unfold your glasses to connect.", "Glasses") }
      return ("Not Connected", "Your glasses work with Meta AI as usual until you connect.", "Glasses")
    }
    if model.sessionPaused { return ("Paused", "Tap your glasses to resume.", "pause.circle") }
    return ("Ready", "Look at \(page) and press capture.", "camera.viewfinder")
  }

  // MARK: - Bottom: the latest answer, as a row

  @ViewBuilder
  private var bottom: some View {
    VStack(spacing: 0) {
      if model.speechHeld {
        Divider()
        HStack {
          Label("Glasses audio disconnected", systemImage: "speaker.slash")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Play Here") { model.playOnPhone() }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
      }
      if let result = latest {
        Divider()
        Button(action: openWorkspace) {
          HStack(spacing: 12) {
            if let photo = model.lastPhoto {
              // A thumbnail with a hairline edge, as in Food Truck's OrderRow.
              let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
              Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(shape)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
              Text(result.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
              Text(result.text)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the answer")
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

  // MARK: - Setup: before the app is linked to the glasses in Meta AI

  /// What the glasses will do, then one action (the order Meta's CameraAccess onboarding uses).
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
    .padding(.horizontal, 20)
    .padding(.bottom, 16)
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
          Toggle("Save Photos to Photos", isOn: Binding(
            get: { model.savePhotosToLibrary },
            set: { on in Task { await model.setSavePhotos(on) } }))
        } header: {
          Text("Solving")
        } footer: {
          Text("Fast Answers start sooner and cost more. Sharper Photos read small print better but take longer. Save Photos to Photos adds each photo your glasses take to your library.")
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
          Button("Unlink from Meta AI", role: .destructive) { model.disconnectGlasses() }
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
