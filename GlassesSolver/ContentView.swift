import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var showSettings = false
  @State private var showStartSession = false
  @State private var showConversation = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          statusCard

          if !model.isRegistered {
            Button {
              model.connectGlasses()
            } label: {
              Label("Connect glasses", systemImage: "eyeglasses")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.registrationState == .registering)
          }

          Button {
            Task { await model.solve() }
          } label: {
            Group {
              if model.isBusy {
                ProgressView().tint(.white)
              } else {
                Label("Solve", systemImage: "camera.viewfinder")
              }
            }
            .font(.title2.bold())
            .frame(maxWidth: .infinity, minHeight: 64)
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isBusy || !model.isRegistered || !model.canSolve)

          if model.speechHeld {
            VStack(alignment: .leading, spacing: 10) {
              Label("Paused: the glasses' audio disconnected", systemImage: "speaker.slash.fill")
                .font(.headline)
                .foregroundStyle(.orange)
              Text("So it isn't read out loud on the phone. It carries on when the glasses reconnect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              HStack {
                Button("Play on phone", systemImage: "iphone.radiowaves.left.and.right") { model.playOnPhone() }
                Spacer()
                Button("Stop", systemImage: "stop.fill") { model.stopSpeaking() }
              }
              .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
          }

          sessionSection

          if let photo = model.lastPhoto {
            Image(uiImage: photo)
              .resizable()
              .scaledToFit()
              .frame(maxHeight: 240)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }

          if !model.shownAnswer.isEmpty || !model.lastAnswer.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              // While it arrives, only complete lines, so half-written math isn't shown.
              let text = model.phase == .thinking ? ClaudeClient.completeLines(model.shownAnswer) : model.shownAnswer
              let written = WrittenAnswer.parse(text)
              if written.isEmpty {
                Text(Self.withoutWrittenMath(text.isEmpty ? model.lastAnswer : text))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
              } else {
                WrittenAnswerView(
                  html: written.html(now: model.linePosition.map { ($0.problem, $0.line) }))
                  .frame(height: 440)
                  .clipShape(RoundedRectangle(cornerRadius: 8))
              }
              HStack {
                Button("Repeat", systemImage: "speaker.wave.2") { model.repeatAnswer() }
                Button("Repeat line", systemImage: "pencil.line") { model.repeatWriteLine() }
                Spacer()
                Button("Stop", systemImage: "stop.fill") { model.stopSpeaking() }
              }
              .buttonStyle(.bordered)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
          }
        }
        .padding()
      }
      .navigationTitle("Glasses Solver")
      .toolbar {
        if model.sessionActive {
          ToolbarItem(placement: .topBarLeading) {
            Label(model.sessionPaused ? "Paused" : "Session", systemImage: "circle.fill")
              .labelStyle(.titleAndIcon)
              .font(.caption.bold())
              .foregroundStyle(model.sessionPaused ? .orange : .green)
          }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Conversation", systemImage: "bubble.left.and.bubble.right") { showConversation = true }
          Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(model: model)
      }
      .sheet(isPresented: $showConversation) {
        ConversationView(model: model)
      }
      .sheet(isPresented: $showStartSession) {
        StartSessionView(model: model)
      }
      .alert(
        "Allow camera access?",
        isPresented: $model.showCameraPermissionPrompt
      ) {
        Button("Open Meta AI") { Task { await model.confirmCameraPermission() } }
        Button("Cancel", role: .cancel) { model.cancelCameraPermission() }
      } message: {
        Text(
          "The Meta AI app will open so you can let this app use your glasses' camera. "
            + "Choose Allow always: Allow once ends with the session, and it can't be granted again while your phone is locked."
        )
      }
      .alert(
        "Something went wrong",
        isPresented: Binding(
          get: { model.errorMessage != nil },
          set: { if !$0 { model.errorMessage = nil } }
        )
      ) {
        Button("Copy log") { UIPasteboard.general.string = DiagnosticsLog.shared.text }
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.errorMessage ?? "")
      }
    }
  }

  /// An answer's text without the written math after "||" on its lines.
  static func withoutWrittenMath(_ text: String) -> String {
    text.components(separatedBy: "\n").map(Speaker.spokenPart).joined(separator: "\n")
  }

  @ViewBuilder
  private var sessionSection: some View {
    if model.sessionActive {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Circle()
            .fill(model.sessionPaused ? Color.orange : Color.green)
            .frame(width: 10, height: 10)
          Text(model.sessionPaused ? "Session paused" : "Session active")
            .font(.headline)
        }
        Text(shutterText)
          .font(.subheadline)
          .foregroundStyle(isShutterUnavailable ? Color.red : Color.secondary)
        Text("Prompt: \(model.sessionPrompt)")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Stop session", systemImage: "stop.circle", role: .destructive) {
          model.stopSession()
        }
        .buttonStyle(.bordered)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    } else {
      Button {
        showStartSession = true
      } label: {
        Group {
          if model.isStartingSession {
            ProgressView()
          } else {
            Label("Start Session", systemImage: "button.programmable")
          }
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(model.isStartingSession || model.isBusy || !model.isRegistered || !model.canSolve)
    }
  }

  private var isShutterUnavailable: Bool {
    if case .unavailable = model.shutterStatus { return true }
    return false
  }

  private var shutterText: String {
    switch model.shutterStatus {
    case .off, .activating:
      return "Connecting to the capture button…"
    case .active:
      return "Press the capture button on your glasses to solve. Tap the touchpad once to pause, or touch and hold to end."
    case .unavailable(let reason, _):
      return "Capture button unavailable. \(reason) The Solve button above still works."
    }
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.statusText).font(.headline)
      Text("Meta AI: \(model.registrationState.description)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(model.hasActiveDevice ? "Glasses: connected" : "Glasses: not detected")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if model.testMode {
        Label("Test mode: Claude isn't called (Settings)", systemImage: "testtube.2")
          .font(.subheadline.bold())
          .foregroundStyle(.orange)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SettingsView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var keyDraft = ""
  @State private var azureKeyDraft = ""
  /// Re-read when Settings opens, so newly downloaded voices show up.
  @State private var voices: [(id: String, label: String)] = []
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
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
        } header: {
          Text("Anthropic API key")
        } footer: {
          Text(model.hasAPIKey ? "A key is saved in the Keychain on this phone." : "No key saved yet.")
        }

        Section {
          Toggle("Fast answers", isOn: $model.fastAnswers)
        } footer: {
          Text(
            "Claude's fast mode: the same model, just as careful with the math, but it thinks and writes "
              + "about twice as fast, so the first words come sooner. It costs twice as much per answer. "
              + "If your account can't use it, standard speed is used automatically."
          )
        }

        Section {
          Toggle("Test mode (no Claude)", isOn: $model.testMode)
        } footer: {
          Text(
            "Runs everything (glasses, photo, speech) but skips Claude, so it's free. You'll hear a sample answer. "
              + "With the phone locked it waits 35 seconds first, longer than iOS normally lets a background app run, "
              + "so hearing the answer means the app stays running."
          )
        }

        Section {
          Picker("Voice", selection: $model.voiceEngine) {
            Text("Azure (online, clearest)").tag(AppModel.VoiceEngine.azure)
            if model.hasNeuralVoice {
              Text("Heart (built in, offline)").tag(AppModel.VoiceEngine.heart)
            }
            Text("Apple").tag(AppModel.VoiceEngine.apple)
          }
          if model.voiceEngine == .azure {
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
          }
          if model.voiceEngine == .apple {
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
          }
          Button("Preview voice", systemImage: "play.circle") { model.previewVoice() }
          Button("Compare voices", systemImage: "person.2.wave.2") { model.compareVoices() }
          Button("Match speed to 150 words a minute", systemImage: "gauge.with.needle") { model.matchSpeed() }
          VStack(alignment: .leading) {
            Text("Speaking speed")
            Slider(value: $model.speechRate, in: Speaker.rateRange) {
              Text("Speaking speed")
            } minimumValueLabel: {
              Image(systemName: "tortoise")
            } maximumValueLabel: {
              Image(systemName: "hare")
            }
          }
          VStack(alignment: .leading) {
            Text("Time to write each line")
            Slider(value: $model.writingTime, in: Speaker.writingTimeRange) {
              Text("Time to write each line")
            } minimumValueLabel: {
              Text("Less").font(.caption)
            } maximumValueLabel: {
              Text("More").font(.caption)
            }
          }
          Toggle("Pause after each part of a line", isOn: $model.dictateInParts)
          Button("Test voice", systemImage: "speaker.wave.2") { model.testVoice() }
          Button("Test limit definition", systemImage: "function") { model.testLimitDefinition() }
          Button("Reset speed and writing time") {
            model.speechRate = Speaker.defaultRate
            model.writingTime = 1
          }
          .disabled(model.speechRate == Speaker.defaultRate && model.writingTime == 1)
        } header: {
          Text("Voice")
        } footer: {
          Text(
            "Using \(model.voiceDescription). Azure is the clearest: it needs internet and your own free key "
              + "(portal.azure.com, a Speech resource on the Free F0 tier; copy its key and region), and uses Heart "
              + "when it can't be reached. Heart runs inside the app and works offline. "
              + "Enhanced and Premium voices sound far more natural than Default "
              + "ones. Download them in iOS Settings → Accessibility → Read & Speak → Voices → English (for "
              + "example Ava, Zoe or Evan, Premium), then come back here and pick one. Compare voices reads "
              + "one real line of dictation in each voice, so you can choose by ear; Match speed sets the "
              + "current voice to about 150 words a minute. Answers dictate each "
              + "line to write a few words at a time and pause while you write each part (turn off \"Pause after "
              + "each part\" to hear the whole line first, then one pause). Double-tap the glasses' touchpad to "
              + "hear the last line again; double-tap again for slower."
          )
        }

        Section {
          Toggle("High-resolution photo (experimental)", isOn: $model.useHighResPhoto)
        } footer: {
          Text("Uses the SDK's experimental standalone photo capture. Sharper for small print, but slower to transfer.")
        }

        Section {
          NavigationLink("Diagnostics log") { DiagnosticsView() }
        } footer: {
          Text("Session, capture-button and error details. Copy it and send it along when reporting a problem.")
        }

        if model.isRegistered {
          Section {
            Button("Disconnect glasses from this app", role: .destructive) {
              model.disconnectGlasses()
            }
          }
        }
      }
      .navigationTitle("Settings")
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
      .toolbar {
        Button("Done") { dismiss() }
      }
    }
  }
}

struct StartSessionView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var prompt = ClaudeClient.defaultPrompt

  private var trimmedPrompt: String {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Prompt", text: $prompt, axis: .vertical)
            .lineLimit(3...10)
          if prompt != ClaudeClient.defaultPrompt {
            Button("Reset to default") { prompt = ClaudeClient.defaultPrompt }
          }
        } header: {
          Text("Prompt for this session")
        } footer: {
          Text("Sent to Claude with every photo you take with the capture button.")
        }

        Section {
          Label("Press the capture button on the glasses frame to solve.", systemImage: "camera")
          Label("Tap the touchpad once to pause or resume.", systemImage: "hand.tap")
          Label("Touch and hold the touchpad to end the session.", systemImage: "hand.raised")
          Label("You can leave the app or lock your phone.", systemImage: "lock.iphone")
        } header: {
          Text("On your glasses")
        }
      }
      .navigationTitle("Start Session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Start") {
            let prompt = trimmedPrompt
            // Dismiss first so a camera-permission alert can appear on the main screen.
            dismiss()
            Task { await model.startSession(prompt: prompt) }
          }
          .disabled(trimmedPrompt.isEmpty)
        }
      }
    }
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
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = log.text }
          .disabled(log.lines.isEmpty)
        Button("Clear", systemImage: "trash") { log.clear() }
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
