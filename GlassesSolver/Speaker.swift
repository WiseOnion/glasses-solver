import AVFoundation

/// Speaks text through the current audio route. When the glasses are connected to the
/// phone as Bluetooth audio (their normal state), that route is the glasses' speakers.
///
/// Speech flows the way iOS reads text normally: explanation text goes to the synthesizer as
/// whole utterances (its own sentence pauses sound natural; splitting sentences into separate
/// utterances made audible stop-start gaps), and everything is queued at once, with the
/// synthesizer's own `postUtteranceDelay` for pauses rather than app timers. Lines starting
/// "Write:" are dictated as one slightly slower utterance (commas give the chunk pauses),
/// followed by a pause long enough to write the line by hand. `repeatLastWriteLine()` says
/// the latest one again, then carries on from where it was.
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
  /// Dictation speed relative to `rate`, and the short beat before a Write line.
  private static let dictationRateFactor: Float = 0.88
  private static let beforeWritePause: TimeInterval = 0.3

  var rate: Float = Speaker.defaultRate
  var writingTimeScale: Double = 1
  /// The chosen voice; nil means the best installed voice for the phone's language.
  var voiceIdentifier: String?
  /// The Write line most recently dictated, for `repeatLastWriteLine()`.
  private(set) var lastWriteLine: String?

  private struct Segment {
    let text: String
    let rate: Float
    let pauseAfter: TimeInterval
    /// Set on a dictated line.
    let writeLine: String?
  }

  private let synthesizer = AVSpeechSynthesizer()
  /// What's queued now, in order, and which utterance is which segment.
  private var script: [Segment] = []
  private var utteranceIndex: [ObjectIdentifier: Int] = [:]
  /// Utterances handed to the synthesizer, kept alive so a late delegate callback can't be
  /// mistaken for a new utterance at a reused address.
  private var utterances: [AVSpeechUtterance] = []
  private var retiredUtterances: [AVSpeechUtterance] = []
  private var currentIndex: Int?
  private var currentFinished = false
  private var outstanding = 0
  private var keepAlivePlayer: AVAudioPlayer?
  private var stopKeepAliveAfterSpeech = false
  private var interruptionObserver: NSObjectProtocol?

  /// True while anything is queued or being said (including a writing pause).
  var isActive: Bool { outstanding > 0 }

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
    reset()
    activateSession()
    lastWriteLine = nil
    let voice = resolvedVoice
    let voiceName = voice.map { $0.name + " (" + Self.qualityName($0.quality) + ")" } ?? "default"
    diag("audio", "speaking \(text.count) characters at rate \(rate), voice \(voiceName), via \(Self.routeDescription)")
    enqueue(segments(for: text), voice: voice)
  }

  /// Says the latest Write line again, then continues with whatever was left to say.
  @discardableResult
  func repeatLastWriteLine() -> Bool {
    guard let line = lastWriteLine else { return false }
    var remaining: [Segment] = []
    if let index = currentIndex {
      let start = currentFinished ? index + 1 : index
      if start < script.count { remaining = Array(script[start...]) }
      // A line being dictated (or in its writing pause) is covered by the repeat itself.
      if !currentFinished, remaining.first?.writeLine != nil { remaining.removeFirst() }
    }
    reset()
    activateSession()
    diag("audio", "repeating the last Write line")
    enqueue([dictation(line, cue: "Again.")] + remaining, voice: resolvedVoice)
    return true
  }

  func stop() {
    reset()
    if stopKeepAliveAfterSpeech { endKeepAlive() }
  }

  // MARK: - Queue

  private func reset() {
    retiredUtterances = utterances
    utterances.removeAll()
    utteranceIndex.removeAll()
    script.removeAll()
    currentIndex = nil
    currentFinished = false
    outstanding = 0
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func enqueue(_ segments: [Segment], voice: AVSpeechSynthesisVoice?) {
    for segment in segments {
      let utterance = AVSpeechUtterance(string: segment.text)
      utterance.rate = segment.rate
      utterance.voice = voice
      utterance.postUtteranceDelay = segment.pauseAfter
      script.append(segment)
      utterances.append(utterance)
      utteranceIndex[ObjectIdentifier(utterance)] = script.count - 1
      outstanding += 1
      synthesizer.speak(utterance)
    }
  }

  private func utteranceStarted(_ id: ObjectIdentifier) {
    guard let index = utteranceIndex[id] else { return }
    currentIndex = index
    currentFinished = false
    if let line = script[index].writeLine { lastWriteLine = line }
  }

  private func utteranceEnded(_ id: ObjectIdentifier) {
    guard let index = utteranceIndex.removeValue(forKey: id) else { return }
    if index == currentIndex { currentFinished = true }
    outstanding = max(0, outstanding - 1)
    if outstanding == 0, stopKeepAliveAfterSpeech { endKeepAlive() }
  }

  /// Explanation paragraphs between Write lines become one utterance each run; each Write
  /// line becomes one dictated utterance.
  private func segments(for text: String) -> [Segment] {
    var result: [Segment] = []
    var prose: [String] = []
    func flushProse(beforeWrite: Bool) {
      guard !prose.isEmpty else { return }
      let joined = prose.map { line in
        line.last.map { ".!?:;".contains($0) } == true ? line : line + "."
      }.joined(separator: " ")
      result.append(
        Segment(text: joined, rate: rate, pauseAfter: beforeWrite ? Self.beforeWritePause : 0, writeLine: nil))
      prose.removeAll()
    }
    for paragraph in Self.speakable(text).components(separatedBy: "\n") {
      if let line = Self.writeLine(in: paragraph) {
        flushProse(beforeWrite: true)
        result.append(dictation(line, cue: "Write."))
      } else {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { prose.append(trimmed) }
      }
    }
    flushProse(beforeWrite: false)
    return result
  }

  /// "Write." and the line as one slower utterance, then time to write it.
  private func dictation(_ line: String, cue: String) -> Segment {
    Segment(
      text: cue + " " + line, rate: rate * Self.dictationRateFactor,
      pauseAfter: writingPause(for: line), writeLine: line)
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

  // MARK: - Voices

  /// Installed voices in the phone's language, best quality first. Novelty and Personal
  /// Voice voices are left out.
  static func availableVoices() -> [AVSpeechSynthesisVoice] {
    let language = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
    return AVSpeechSynthesisVoice.speechVoices()
      .filter {
        $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice)
          && !$0.voiceTraits.contains(.isPersonalVoice)
      }
      .sorted {
        $0.quality.rawValue != $1.quality.rawValue
          ? $0.quality.rawValue > $1.quality.rawValue
          : $0.name < $1.name
      }
  }

  /// The best installed voice for the phone's exact language (e.g. en-US), then any variant.
  static var bestVoice: AVSpeechSynthesisVoice? {
    let code = AVSpeechSynthesisVoice.currentLanguageCode()
    let voices = availableVoices()
    return voices.first { $0.language == code } ?? voices.first ?? AVSpeechSynthesisVoice(language: code)
  }

  /// The chosen voice if it's still installed, otherwise the best one.
  var resolvedVoice: AVSpeechSynthesisVoice? {
    voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.bestVoice
  }

  static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
    switch quality {
    case .premium: "Premium"
    case .enhanced: "Enhanced"
    default: "Default"
    }
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
    for token in ["**", "__", "`", "#", #"\("#, #"\)"#, #"\["#, #"\]"#] {
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
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceStarted(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceEnded(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceEnded(id) }
  }
}
