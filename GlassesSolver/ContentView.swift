import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var showSettings = false

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
        Button("Settings", systemImage: "gearshape") { showSettings = true }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(model: model)
      }
      .alert(
        "Allow camera access?",
        isPresented: $model.showCameraPermissionPrompt
      ) {
        Button("Open Meta AI") { Task { await model.confirmCameraPermission() } }
        Button("Cancel", role: .cancel) {}
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
