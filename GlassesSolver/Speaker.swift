import AVFoundation

/// Speaks text through the current audio route. When the glasses are connected to the
/// phone as Bluetooth audio (their normal state), that route is the glasses' speakers.
///
/// Also keeps the app running while an answer is pending with the phone locked: with the
/// `audio` background mode, iOS doesn't suspend an app that is playing audio, so a silent
/// loop covers the Claude call, and the spoken answer itself covers the rest.
@MainActor
final class Speaker: NSObject {
  private let synthesizer = AVSpeechSynthesizer()
  private var keepAlivePlayer: AVAudioPlayer?
  private var stopKeepAliveAfterSpeech = false
  private var interruptionObserver: NSObjectProtocol?

  var isSpeaking: Bool { synthesizer.isSpeaking }

  override init() {
    super.init()
    synthesizer.delegate = self
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { note in
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      diag("audio", "interruption \(type == .began ? "began" : type == .ended ? "ended" : "unknown")")
    }
  }

  func speak(_ text: String) {
    activateSession()
    synthesizer.stopSpeaking(at: .immediate)
    diag("audio", "speaking \(text.count) characters via \(Self.routeDescription)")
    synthesizer.speak(AVSpeechUtterance(string: Self.speakable(text)))
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }

  // MARK: - Keep-alive

  /// Starts (or restarts, after an interruption) the silent loop.
  func beginKeepAlive() {
    stopKeepAliveAfterSpeech = false
    activateSession()
    if keepAlivePlayer == nil {
      keepAlivePlayer = try? AVAudioPlayer(data: Self.silentWAV)
      keepAlivePlayer?.numberOfLoops = -1
      keepAlivePlayer?.volume = 0
    }
    guard let player = keepAlivePlayer else {
      diag("audio", "keep-alive: couldn't create the player")
      return
    }
    if !player.isPlaying {
      let started = player.play()
      diag("audio", "keep-alive \(started ? "started" : "FAILED to start") via \(Self.routeDescription)")
    }
  }

  /// Stops the loop once the current speech finishes (speech keeps the app running too).
  func endKeepAliveAfterSpeech() {
    guard keepAlivePlayer != nil else { return }
    if synthesizer.isSpeaking {
      stopKeepAliveAfterSpeech = true
    } else {
      endKeepAlive()
    }
  }

  func endKeepAlive() {
    stopKeepAliveAfterSpeech = false
    guard let player = keepAlivePlayer else { return }
    player.stop()
    keepAlivePlayer = nil
    diag("audio", "keep-alive stopped")
  }

  // MARK: - Helpers

  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    } catch {
      diag("audio", "audio session error: \(ErrorDetail.describe(error))")
    }
  }

  private func speechEnded() {
    guard stopKeepAliveAfterSpeech, !synthesizer.isSpeaking else { return }
    endKeepAlive()
  }

  private static var routeDescription: String {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    guard !outputs.isEmpty else { return "no output" }
    return outputs.map { "\($0.portType.rawValue) \($0.portName)" }.joined(separator: ", ")
  }

  /// One second of 8 kHz mono 16-bit silence as a WAV file.
  private static let silentWAV: Data = {
    let sampleRate: UInt32 = 8000
    let samples = Data(count: Int(sampleRate) * 2)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + samples.count))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))  // fmt chunk size
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(sampleRate)
    append(sampleRate * 2)  // byte rate
    append(UInt16(2))  // block align
    append(UInt16(16))  // bits per sample
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(samples.count))
    data.append(samples)
    return data
  }()

  /// Drops Markdown/LaTeX characters that TTS would read out literally.
  private static func speakable(_ text: String) -> String {
    var result = text
    for token in ["**", "__", "`", "#", "\\(", "\\)", "\\[", "\\]"] {
      result = result.replacingOccurrences(of: token, with: "")
    }
    return result
  }
}

extension Speaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.speechEnded() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.speechEnded() }
  }
}
