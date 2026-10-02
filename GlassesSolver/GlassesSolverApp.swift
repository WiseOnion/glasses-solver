import MWDATCore
import SwiftUI

@main
struct GlassesSolverApp: App {
  @State private var model: AppModel

  init() {
    // Must run before anything touches `Wearables.shared`.
    do {
      try Wearables.configure()
    } catch {
      NSLog("[GlassesSolver] Failed to configure Wearables SDK: \(error)")
    }
    _model = State(initialValue: AppModel())
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
