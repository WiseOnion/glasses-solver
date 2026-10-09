import MWDATCore
import SwiftUI

@main
struct GlassesSolverApp: App {
  @State private var model: AppModel

  init() {
    // First, so the log shows how the last run ended and everything after this.
    DiagnosticsLog.reportPreviousRun()
    AppEventsLog.shared.start()
    // Must run before anything touches `Wearables.shared`.
    var setupError: String?
    do {
      try Wearables.configure()
      diag("sdk", "Wearables.configure() OK")
    } catch {
      setupError = ErrorDetail.describe(error)
      diag("sdk", "Wearables.configure() FAILED: \(setupError ?? "")")
    }
    _model = State(initialValue: AppModel(sdkSetupError: setupError))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onOpenURL { url in
          model.handleOpenURL(url)
        }
    }
  }
}
