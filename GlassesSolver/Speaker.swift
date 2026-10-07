import AVFoundation
import NaturalLanguage

/// Speaks text through the current audio route. When the glasses are connected to the
/// phone as Bluetooth audio (their normal state), that route is the glasses' speakers.
///
/// Answers are spoken from a queue, one sentence at a time. Lines starting "Write:" are
/// dictated: read a little slower in comma-separated chunks, then followed by a pause long
/// enough to write the line by hand (handwriting runs around one character a second, far
/// slower than speech). `repeatLastWriteLine()` says the latest one again and then carries on.
///
/// Also keeps the app running while an answer is pending with the phone locked: with the
/// `audio` background mode, iOS doesn't suspend an app that is playing audio, so a silent
/// loop covers the Claude call, and the spoken answer itself covers the rest.
@MainActor
final class Speaker: NSObject {
  /// Slider range for the speaking speed (AVSpeechUtterance rates run 0...1; 0.5 is iOS's default).
  static let rateRange: ClosedRange<Float> = 0.35...0.6
  /// A little slower than iOS's default: steps of math are dense to follow by ear.
  static let defaultRate: Float = 0.46
  /// Slider range for the writing pause, as a multiple of the estimated writing time.
  static let writingTimeRange: ClosedRange<Double> = 0.5...2.5
  /// Pause after each sentence, and a longer one between paragraphs.
  private static let sentencePause: TimeInterval = 0.25
  private static let paragraphPause: TimeInterval = 0.6
  /// Pause between chunks of a Write line, and the dictation speed relative to `rate`.
  private static let chunkPause: TimeInterval = 0.45
  private static let dictationRateFactor: Float = 0.9

  var rate: Float = Speaker.defaultRate
  var writingTimeScale: Double = 1
  /// The Write line most recently dictated, for `repeatLastWriteLine()`.
  private(set) var lastWriteLine: String?

  private struct Segment {
    let text: String
    let rate: Float
    let pauseAfter: TimeInterval
    /// Set on the first segment of a dictated line.
    let writeLine: String?
    /// Part of a dictated line (the cue or a chunk).
    let isDictation: Bool
  }

  private let synthesizer = AVSpeechSynthesizer()
  private var queue: [Segment] = []
  private var current: (id: ObjectIdentifier, segment: Segment)?
  private var pauseTask: Task<Void, Never>?
  /// Bumped whenever the queue is replaced, so a stale pause can't start the next segment.
  private var generation = 0
  private var voice: AVSpeechSynthesisVoice?
  private var keepAlivePlayer: AVAudioPlayer?
  private var stopKeepAliveAfterSpeech = false
  private var interruptionObserver: NSObjectProtocol?

  /// True while anything is queued, being said, or in a pause between segments.
  var isActive: Bool { current != nil || pauseTask != nil || !queue.isEmpty }

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
    resetQueue()
    activateSession()
    voice = Self.voice
    let voiceName = voice.map { $0.name + " (" + Self.qualityName($0.quality) + ")" } ?? "default"
    diag("audio", "speaking \(text.count) characters at rate \(rate), voice \(voiceName), via \(Self.routeDescription)")
    lastWriteLine = nil
    queue = segments(for: text)
    playNext()
  }

  /// Says the latest Write line again, then continues with whatever was left to say.
  @discardableResult
  func repeatLastWriteLine() -> Bool {
    guard let line = lastWriteLine else { return false }
    let interrupted = current?.segment
    let remaining = queue
    resetQueue()
    activateSession()
    diag("audio", "repeating the last Write line")
    // Re-say an interrupted explanation sentence afterwards; a half-said chunk of the same
    // line is covered by the repeat itself.
    var resume: [Segment] = []
    if let interrupted, !interrupted.isDictation {
      resume = [interrupted]
    }
    queue = writeSegments(line, cue: "Again.") + resume + remaining
    playNext()
    return true
  }

  func stop() {
    resetQueue()
    if stopKeepAliveAfterSpeech { endKeepAlive() }
  }

  // MARK: - Queue

  private func resetQueue() {
    generation += 1
    queue.removeAll()
    pauseTask?.cancel()
    pauseTask = nil
    current = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func playNext() {
    guard !queue.isEmpty else {
      speechEnded()
      return
    }
    let segment = queue.removeFirst()
    if let line = segment.writeLine { lastWriteLine = line }
    let utterance = AVSpeechUtterance(string: segment.text)
    utterance.rate = segment.rate
    utterance.voice = voice
    current = (ObjectIdentifier(utterance), segment)
    synthesizer.speak(utterance)
  }

  private func utteranceFinished(_ id: ObjectIdentifier, cancelled: Bool) {
    // Cancellations come from resetQueue(), which has already moved on.
    guard let finished = current, finished.id == id, !cancelled else { return }
    current = nil
    let generation = self.generation
    pauseTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(finished.segment.pauseAfter))
      guard let self, !Task.isCancelled, self.generation == generation else { return }
      self.pauseTask = nil
      self.playNext()
    }
  }

  private func speechEnded() {
    if stopKeepAliveAfterSpeech { endKeepAlive() }
  }

  private func segments(for text: String) -> [Segment] {
    var result: [Segment] = []
    for paragraph in Self.speakable(text).components(separatedBy: "\n") {
      if let line = Self.writeLine(in: paragraph) {
        result += writeSegments(line, cue: "Write.")
        continue
      }
      let sentences = Self.sentences(in: paragraph)
      for (index, sentence) in sentences.enumerated() {
        let pause = index == sentences.count - 1 ? Self.paragraphPause : Self.sentencePause
        result.append(Segment(text: sentence, rate: rate, pauseAfter: pause, writeLine: nil, isDictation: false))
      }
    }
    return result
  }

  /// "Write." then the line in comma-separated chunks, then time to write it.
  private func writeSegments(_ line: String, cue: String) -> [Segment] {
    let chunks = line.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var result = [Segment(text: cue, rate: rate, pauseAfter: 0.35, writeLine: line, isDictation: true)]
    for (index, chunk) in chunks.enumerated() {
      let isLast = index == chunks.count - 1
      result.append(
        Segment(
          text: chunk, rate: rate * Self.dictationRateFactor,
          pauseAfter: isLast ? writingPause(for: line) : Self.chunkPause, writeLine: nil, isDictation: true))
    }
    return result
  }

  /// Roughly 0.5 seconds of writing per spoken word (each is about one symbol on paper),
  /// clamped to 2.5–12 seconds, then scaled by the writing-time setting.
  func writingPause(for line: String) -> TimeInterval {
    let words = line.split(whereSeparator: { $0 == " " || $0 == "," }).count
    return min(max(1 + 0.5 * Double(words), 2.5), 12) * writingTimeScale
  }

  /// The text after "Write:" if this paragraph is a Write line.
  private static func writeLine(in paragraph: String) -> String? {
    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("write:") else { return nil }
    let line = trimmed.dropFirst("write:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
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

  /// Stops the loop once the current speech finishes, including writing pauses, so the app
  /// keeps running through them with the phone locked.
  func endKeepAliveAfterSpeech() {
    guard keepAlivePlayer != nil else { return }
    if isActive {
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

  /// The best installed voice for the phone's language. Enhanced and Premium voices
  /// (downloaded in iOS Settings → Accessibility → Spoken Content → Voices) sound much clearer.
  static var voice: AVSpeechSynthesisVoice? {
    let language = AVSpeechSynthesisVoice.currentLanguageCode()
    let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
    return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
      ?? AVSpeechSynthesisVoice(language: language)
  }

  static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
    switch quality {
    case .premium: "Premium"
    case .enhanced: "Enhanced"
    default: "standard"
    }
  }

  private static func sentences(in paragraph: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = paragraph
    return tokenizer.tokens(for: paragraph.startIndex..<paragraph.endIndex)
      .map { paragraph[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
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

  /// A safety net for notation that slips into the answer despite the system prompt: drops
  /// Markdown/LaTeX characters and says math and calculus notation in words, in the same
  /// forms the prompt asks for. iOS reads "sin" as the word "sin", "3/4" as a date, and
  /// skips "=" entirely. The rules are tested against sample answers (see README).
  static func speakable(_ text: String) -> String {
    var result = text
    for token in ["**", "__", "`", "#", "\(", "\)", "\[", "\]"] {
      result = result.replacingOccurrences(of: token, with: "")
    }
    result = applying(calculusRules, to: result)
    for (symbol, spoken) in symbolWords {
      result = result.replacingOccurrences(of: symbol, with: spoken)
    }
    return applying(cleanupRules, to: result).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func applying(_ rules: [(String, String)], to text: String) -> String {
    rules.reduce(text) { text, rule in
      text.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
    }
  }

  /// Derivatives, limits, trig and exponents, in order (earlier rules feed later ones).
  private static let calculusRules: [(String, String)] = [
    (#"\bd([a-zA-Z])\s*/\s*d([a-zA-Z])\b"#, "d $1 d $2"),
    (#"\bd\s*/\s*d([a-zA-Z])\b"#, "the derivative with respect to $1 of"),
    (#"\b([a-zA-Z])(?:''|″)\s*\("#, "$1 double prime of ("),
    (#"\b([a-zA-Z])(?:'|′)\s*\("#, "$1 prime of ("),
    (#"\b([a-zA-Z])(?:''|″)(?=[\s,.;:)]|$)"#, "$1 double prime"),
    (#"\b([a-zA-Z])(?:'|′)(?=[\s,.;:)]|$)"#, "$1 prime"),
    (#"\blim\s*_?\{?\s*([a-zA-Z])\s*(?:→|->)\s*(-?∞|-?[\w.]+)\}?\s*"#, "the limit as $1 approaches $2, of "),
    (#"\barc(sin|cos|tan|sec|csc|cot)\b"#, "inverse $1"),
    (#"\b(sin|cos|tan|sec|csc|cot)\s*(?:\^\s*\(?\s*-\s*1\s*\)?|⁻¹)"#, "inverse $1"),
    (#"\b(sin|cos|tan|sec|csc|cot)\s*(?:\^\s*2|²)\s*"#, "$1 squared of "),
    (#"\bsin\s*\("#, "sine of ("), (#"\bsin\b"#, "sine"),
    (#"\bcos\s*\("#, "cosine of ("), (#"\bcos\b"#, "cosine"),
    (#"\btan\s*\("#, "tangent of ("), (#"\btan\b"#, "tangent"),
    (#"\bsec\s*\("#, "secant of ("), (#"\bsec\b"#, "secant"),
    (#"\bcsc\s*\("#, "cosecant of ("), (#"\bcsc\b"#, "cosecant"),
    (#"\bcot\s*\("#, "cotangent of ("), (#"\bcot\b"#, "cotangent"),
    (#"\bln\s*\("#, "natural log of ("), (#"\bln\b"#, "natural log"),
    (#"\blim\b"#, "the limit"),
    (#"\^\s*\(\s*(-?\d+)\s*\)"#, " to the $1"),
    (#"\^\s*\(([^()]+)\)"#, " raised to the exponent $1, end exponent"),
    (#"\^\s*2\b"#, " squared"),
    (#"\^\s*3\b"#, " cubed"),
    (#"\^\s*(-?\d+)"#, " to the $1"),
    (#"\^\s*([a-zA-Z])\b"#, " to the $1"),
  ]

  private static let symbolWords: [(String, String)] = [
    ("→", " approaches "), ("->", " approaches "), ("∞", " infinity "), ("θ", " theta "),
    ("Δ", " delta "), ("±", " plus or minus "), ("≠", " does not equal "), ("≈", " is about "),
    ("≤", " is less than or equal to "), ("≥", " is greater than or equal to "), ("=", " equals "),
    ("×", " times "), ("·", " times "), ("÷", " divided by "), ("√", " the square root of "),
    ("π", " pi "), ("²", " squared"), ("³", " cubed"), ("°", " degrees"), ("−", " minus "),
    ("+", " plus "), (" < ", " is less than "), (" > ", " is greater than "), (" - ", " minus "),
  ]

  private static let cleanupRules: [(String, String)] = [
    (#"(?<![\w)\]])-(?=[\w(∞.])"#, "negative "),  // a sign, not a hyphenated word
    (#"(?<![\d/])(\d+)\s*/\s*(\d+)(?![\d/])"#, "$1 over $2"),  // 3/4, but not 1/2/2026
    (#"(?<!\d)/|/(?!\d)"#, " over "),  // x/2, 1/x
    (#"\(\s*([\w.]+)\s*\)"#, "$1"),  // (x) → x
    (#"(?m)^\s*[-•*]\s+"#, ""),  // bullets
    (#"[ \t]{2,}"#, " "),
    (#"\s+([,.;:])"#, "$1"),
  ]
}

extension Speaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceFinished(id, cancelled: false) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceFinished(id, cancelled: true) }
  }
}
