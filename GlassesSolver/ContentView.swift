import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var showSettings = false
  @State private var showStartSession = false

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
          .disabled(model.isBusy || !model.isRegistered || !model.hasAPIKey)

          sessionSection

          if let photo = model.lastPhoto {
            Image(uiImage: photo)
              .resizable()
              .scaledToFit()
              .frame(maxHeight: 240)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }

          if !model.lastAnswer.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text(model.lastAnswer)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
              HStack {
                Button("Repeat", systemImage: "speaker.wave.2") { model.repeatAnswer() }
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
        ToolbarItem(placement: .topBarTrailing) {
          Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(model: model)
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
        Text("The Meta AI app will open so you can let this app use your glasses' camera.")
      }
      .alert(
        "Something went wrong",
        isPresented: Binding(
          get: { model.errorMessage != nil },
          set: { if !$0 { model.errorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.errorMessage ?? "")
      }
    }
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
      .disabled(model.isStartingSession || !model.isRegistered || !model.hasAPIKey)
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
          Toggle("High-resolution photo (experimental)", isOn: $model.useHighResPhoto)
        } footer: {
          Text("Uses the SDK's experimental standalone photo capture. Sharper for small print, but slower to transfer.")
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
