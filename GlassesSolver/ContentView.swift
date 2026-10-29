import AVFoundation
import SwiftUI
import UIKit

/// The app's look: system colors on a dark background, one accent (iOS blue). Following
/// Apple's guidelines, content uses solid system backgrounds and only controls use Liquid Glass.
enum Theme {
  static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
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
  @State private var tab = Tab.solve
  @State private var showWorkspace = false

  enum Tab: Hashable {
    case solve, history, settings
  }

  var body: some View {
    TabView(selection: $tab) {
      SolveView(model: model, openWorkspace: { showWorkspace = true })
        .tabItem { Label("Solve", systemImage: "viewfinder.circle.fill") }
        .tag(Tab.solve)
      HistoryView(model: model)
        .tabItem { Label("History", systemImage: "clock.fill") }
        .tag(Tab.history)
      SettingsView(model: model)
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
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

/// Solve: one big action in the middle, like Shazam. The subject switch sits at the top,
/// the glasses' status in the navigation bar, and the last answer and the hands-free session
/// low on the screen, within thumb reach.
struct SolveView: View {
  @Bindable var model: AppModel
  let openWorkspace: () -> Void
  @State private var showStartSession = false
  @State private var showSession = false

  private var connected: Bool { model.isRegistered && model.hasActiveDevice }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if model.isRegistered {
          Picker("Subject", selection: $model.subject) {
            ForEach(ClaudeClient.Subject.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 280)
          .disabled(model.isBusy)
          .padding(.top, 8)
        }
        Spacer(minLength: 16)
        hero
        Spacer(minLength: 16)
        bottom
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
      }
      .frame(maxWidth: .infinity)
      .background(background.ignoresSafeArea())
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          statusButton
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $showSession) { SessionControlsView(model: model) }
      .sheet(isPresented: $showStartSession) { StartSessionView(model: model) }
    }
  }

  // MARK: - Background: a soft glow behind the button, color only where the action is

  private var background: some View {
    ZStack {
      Color(.systemBackground)
      RadialGradient(
        colors: [glowColor.opacity(0.28), glowColor.opacity(0.06), .clear], center: .init(x: 0.5, y: 0.46),
        startRadius: 10, endRadius: 360)
    }
  }

  private var glowColor: Color { solveEnabled || !model.isRegistered ? Theme.accent : Color.gray }

  // MARK: - Navigation bar: the glasses' status

  private var statusButton: some View {
    Button {
      if model.sessionActive {
        showSession = true
      } else if !model.isRegistered {
        model.connectGlasses()
      }
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(connected ? Theme.connected : Color(.systemGray))
          .frame(width: 8, height: 8)
        Text(statusText)
          .font(.subheadline.weight(.semibold))
      }
      .foregroundStyle(.primary)
    }
    .accessibilityLabel("Glasses, \(statusText)")
  }

  private var statusText: String {
    if !model.isRegistered { return model.registrationState == .registering ? "Connecting…" : "Not Connected" }
    if model.sessionActive { return model.sessionPaused ? "Session Paused" : "Session Active" }
    return connected ? "Ray-Ban Meta" : "Glasses Asleep"
  }

  // MARK: - The big button

  private var hero: some View {
    VStack(spacing: 0) {
      Text(prompt)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.bottom, 28)
      Button {
        if model.isRegistered {
          Task { await model.solve() }
        } else {
          model.connectGlasses()
        }
      } label: {
        ZStack {
          Circle()
            .fill(
              RadialGradient(
                colors: heroColors, center: .init(x: 0.35, y: 0.28), startRadius: 4, endRadius: 140))
          Circle()
            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
          if model.phase != .idle {
            ProgressView()
              .controlSize(.large)
              .tint(.white)
          } else {
            Image(systemName: model.isRegistered ? "viewfinder" : "eyeglasses")
              .font(.system(size: 72, weight: .light))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 200, height: 200)
        .shadow(color: glowColor.opacity(solveEnabled ? 0.55 : 0), radius: 30, y: 12)
        .background {
          Circle().strokeBorder(glowColor.opacity(0.22)).padding(-18)
          Circle().strokeBorder(glowColor.opacity(0.1)).padding(-40)
        }
      }
      .buttonStyle(PressScaleStyle())
      .disabled(model.isRegistered && !solveEnabled)
      .accessibilityLabel(model.isRegistered ? title : "Connect Glasses")
      Text(title)
        .font(.title.bold())
        .padding(.top, 48)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 6)
        .padding(.horizontal, 32)
    }
  }

  private var heroColors: [Color] {
    guard model.isRegistered else { return [Color(white: 0.24), Color(white: 0.13)] }
    return solveEnabled
      ? [Color(red: 0.29, green: 0.66, blue: 1), Theme.accent, Color(red: 0, green: 0.34, blue: 0.78)]
      : [Color(white: 0.26), Color(white: 0.14)]
  }

  private var solveEnabled: Bool { model.canStartPhoto && model.isRegistered && model.canSolve }

  private var prompt: String {
    model.isRegistered ? (model.subject == .math ? "Look at a problem" : "Look at the page") : " "
  }

  private var title: String {
    guard model.isRegistered else { return "Connect your glasses" }
    switch model.phase {
    case .capturing: return "Taking Photo…"
    case .thinking: return "Solving…"
    case .idle: return "Tap to Solve"
    }
  }

  private var subtitle: String {
    if !model.isRegistered {
      return model.registrationState == .registering
        ? "Finish connecting in the Meta AI app." : "Tap to pair your Ray-Ban Meta glasses."
    }
    var text: String
    if !model.canSolve {
      text = "Add your API key in Settings → Advanced."
    } else if !model.hasActiveDevice {
      text = "Unfold your glasses and put them on."
    } else if model.phase == .thinking {
      text = "Tap again to use a new photo instead."
    } else {
      text = "or press capture on your glasses"
    }
    if model.testMode { text += " · Test Mode" }
    return text
  }

  // MARK: - Low on the screen: the last answer, then the session

  @ViewBuilder
  private var bottom: some View {
    if model.isRegistered {
      VStack(spacing: 12) {
        if model.speechHeld { audioHeld }
        if let result = latest { lastAnswer(result) }
        HStack(spacing: 12) {
          if model.subject == .chemistry {
            Button {
              Task { await model.checkAnswerSheet() }
            } label: {
              Label("Check Sheet", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .glassControl(in: Capsule())
            .disabled(!solveEnabled)
          }
          Button {
            if model.sessionActive { showSession = true } else { showStartSession = true }
          } label: {
            Group {
              if model.isStartingSession {
                ProgressView()
              } else {
                Label(
                  model.sessionActive ? "Glasses Controls" : "Start Hands-Free",
                  systemImage: model.sessionActive ? "dot.radiowaves.left.and.right" : "eyeglasses")
              }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
          }
          .buttonStyle(.plain)
          .glassControl(in: Capsule())
          .disabled(!model.sessionActive && (model.isStartingSession || model.isBusy || !model.canSolve))
        }
      }
    }
  }

  private func lastAnswer(_ result: (title: String, text: String)) -> some View {
    Button(action: openWorkspace) {
      HStack(spacing: 14) {
        if let photo = model.lastPhoto {
          Image(uiImage: photo)
            .resizable()
            .scaledToFill()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(result.title)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text(result.text)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(12)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    .buttonStyle(PressScaleStyle(scale: 0.98))
    .accessibilityHint("Opens the answer")
  }

  private var latest: (title: String, text: String)? {
    if model.subject == .math {
      guard let current = model.currentProblem else { return nil }
      let answer = current.problem?.answer ?? ""
      return ("Problem \(current.label) · Last answer", answer.isEmpty ? "Solving…" : answer)
    }
    let questions = AppModel.questions(in: model.lastAnswer)
    guard !questions.isEmpty else { return nil }
    let names = questions.map(\.label).prefix(6).joined(separator: ", ")
    return ("Last page", questions.count == 1 ? "Question \(names)" : "Questions \(names)")
  }

  private var audioHeld: some View {
    HStack(spacing: 12) {
      Image(systemName: "speaker.slash.fill")
        .foregroundStyle(.orange)
      Text("Glasses audio disconnected")
        .font(.subheadline.weight(.semibold))
      Spacer()
      Button("Play Here") { model.playOnPhone() }
        .font(.subheadline)
    }
    .padding(14)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        Row(symbol: "camera.fill", control: "Capture", action: "Solve"),
        Row(symbol: "hand.tap.fill", control: "Double Tap", action: "Explain"),
        Row(symbol: "checkmark.seal.fill", control: "Double Press", action: "Check"),
        Row(symbol: "arrow.counterclockwise", control: "Hold", action: "Repeat"),
        Row(symbol: "hand.draw.fill", control: "Swipe", action: "Previous / Next"),
        Row(symbol: "pause.circle.fill", control: "Tap", action: "Pause / Resume"),
        Row(symbol: "xmark.circle.fill", control: "Touch and Hold", action: "End Session"),
      ]
      : [
        Row(symbol: "camera.fill", control: "Capture", action: "Solve Page"),
        Row(symbol: "hand.tap.fill", control: "Double Tap", action: "Repeat"),
        Row(symbol: "checkmark.seal.fill", control: "Double Press", action: "Check Answer Sheet"),
        Row(symbol: "hand.draw.fill", control: "Swipe", action: "Replay Previous / Next"),
        Row(symbol: "pause.circle.fill", control: "Tap", action: "Pause / Resume"),
        Row(symbol: "xmark.circle.fill", control: "Touch and Hold", action: "End Session"),
      ]
  }

  var body: some View {
    ForEach(rows, id: \.self) { row in
      Label {
        LabeledContent(row.control, value: row.action)
      } icon: {
        Image(systemName: row.symbol)
          .foregroundStyle(Theme.accent)
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
