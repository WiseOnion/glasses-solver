import SwiftUI

/// The host app for the renderer evaluation (Tests/RendererEvalTests.swift). It shows nothing;
/// it exists so the tests run in an app with the written-answer page bundled.
@main
struct RendererEvalApp: App {
  var body: some Scene {
    WindowGroup { Text("Renderer evaluation") }
  }
}
