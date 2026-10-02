import AVFoundation

/// Speaks text through the current audio route. When the glasses are connected to the
/// phone as Bluetooth audio (their normal state), that route is the glasses' speakers.
@MainActor
final class Speaker {
  private let synthesizer = AVSpeechSynthesizer()

  var isSpeaking: Bool { synthesizer.isSpeaking }

  func speak(_ text: String) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    } catch {
      NSLog("[GlassesSolver] Audio session error: \(error)")
    }
    synthesizer.stopSpeaking(at: .immediate)
    synthesizer.speak(AVSpeechUtterance(string: Self.speakable(text)))
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }

  /// Drops Markdown/LaTeX characters that TTS would read out literally.
  private static func speakable(_ text: String) -> String {
    var result = text
    for token in ["**", "__", "`", "#", "\\(", "\\)", "\\[", "\\]"] {
      result = result.replacingOccurrences(of: token, with: "")
    }
    return result
  }
}
