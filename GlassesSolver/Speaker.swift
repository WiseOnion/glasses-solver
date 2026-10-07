import AVFoundation

/// Speaks text through the current audio route. When the glasses are connected to the
/// phone as Bluetooth audio (their normal state), that route is the glasses' speakers.
///
/// Speech flows the way iOS reads text normally: explanation text goes to the synthesizer as
/// whole utterances (its own sentence pauses sound natural; splitting sentences into separate
/// utterances made audible stop-start gaps), and everything is queued at once, with the
/// synthesizer's own `postUtteranceDelay` for pauses rather than app timers. Lines starting
/// "Write:" are dictated a little slower, a few words at a time, with a pause after each part
/// long enough to write it by hand (or, with `dictateInParts` off, the whole line and then one
/// pause). A line runs past the roughly two seconds of speech that working memory holds, so
/// writing it part by part is how dictation is normally given. `repeatLastWriteLine()` says
/// the latest one again, slower each time it's asked for in a row, then carries on.
///
/// Also keeps the app running while an answer is pending with the phone locked: with the
/// `audio` background mode, iOS doesn't suspend an app that is playing audio, so a silent
/// loop covers the Claude call, and the spoken answer itself covers the rest.
@MainActor
final class Speaker: NSObject {
  /// Slider range for the speaking speed (AVSpeechUtterance rates run 0...1; 0.5 is iOS's default).
  static let rateRange: ClosedRange<Float> = 0.3...0.6
  /// Aims for about 150 words a minute, the middle of what studies of synthetic speech find
  /// listeners follow best (slower helps comprehension; adults pick about 157, children 127).
  /// Apple doesn't publish a rate-to-words mapping and it varies by voice, so the log reports
  /// the measured words per minute (see `logMeasuredRate`). See README, "How the voice dictates".
  static let defaultRate: Float = 0.42
  /// Slider range for the writing pause, as a multiple of the estimated writing time.
  static let writingTimeRange: ClosedRange<Double> = 0.5...2.5
  /// Dictation speed relative to `rate`, and the short beat before a Write line.
  private static let dictationRateFactor: Float = 0.88
  private static let beforeWritePause: TimeInterval = 0.4
  /// Each repeat of the same line in a row is this much slower, at most twice.
  private static let repeatRateFactor: Float = 0.9
  /// A dictated part is at most this many spoken words (about two seconds of speech, what
  /// the phonological loop holds), unless it writes nothing yet ("fraction, top").
  private static let maxGroupWords = 5
  /// Writing time per character on paper (careful handwriting of math runs about one and a
  /// half characters a second), the least pause after a part, the most after a whole line,
  /// and a beat after the last part before the explanation goes on.
  private static let secondsPerCharacter: TimeInterval = 0.7
  private static let minGroupPause: TimeInterval = 1.2
  private static let maxLinePause: TimeInterval = 20
  private static let afterLinePause: TimeInterval = 0.5

  var rate: Float = Speaker.defaultRate
  var writingTimeScale: Double = 1
  /// Pause to write after each part of a Write line (true), or after the whole line.
  var dictateInParts = true
  /// The chosen voice; nil means the best installed voice for the phone's language.
  var voiceIdentifier: String?
  /// The Write line most recently dictated, for `repeatLastWriteLine()`.
  private(set) var lastWriteLine: String?
  /// How many times in a row `lastWriteLine` has been repeated.
  private var repeatCount = 0
  private var nextLineID = 0

  private struct Segment {
    let text: String
    let rate: Float
    let pauseAfter: TimeInterval
    /// Set on every part of a dictated line.
    let writeLine: String?
    /// Shared by the parts of one dictated line.
    var lineID: Int?
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
  /// When each utterance's first and latest words began, for `logMeasuredRate`.
  private var wordTimes: [ObjectIdentifier: (first: Date, last: Date)] = [:]
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
    repeatCount = 0
    let voice = resolvedVoice
    let voiceName = voice.map { $0.name + " (" + Self.qualityName($0.quality) + ")" } ?? "default"
    diag(
      "audio",
      "speaking \(text.count) characters at rate \(rate), \(dictateInParts ? "dictating in parts" : "whole lines"), "
        + "voice \(voiceName), via \(Self.routeDescription)")
    enqueue(segments(for: text), voice: voice)
  }

  /// Says the latest Write line again, part by part and a little slower (slower again if
  /// asked twice in a row), then continues with whatever was left to say.
  @discardableResult
  func repeatLastWriteLine() -> Bool {
    guard let line = lastWriteLine else { return false }
    var remaining: [Segment] = []
    if let index = currentIndex {
      let start = currentFinished ? index + 1 : index
      if start < script.count { remaining = Array(script[start...]) }
      // The rest of a line being dictated (or in a writing pause) is covered by the repeat.
      if let lineID = script[index].lineID {
        remaining = Array(remaining.drop { $0.lineID == lineID })
      }
    }
    repeatCount += 1
    let slowdown = pow(Self.repeatRateFactor, Float(min(repeatCount, 2)))
    reset()
    activateSession()
    diag("audio", "repeating the last Write line (\(repeatCount) in a row)")
    let cue = repeatCount > 1 ? "Again, slower." : "Again."
    enqueue(dictation(line, cue: cue, slowdown: slowdown, inParts: true) + remaining, voice: resolvedVoice)
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
    wordTimes.removeAll()
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
    if let line = script[index].writeLine {
      if line != lastWriteLine { repeatCount = 0 }
      lastWriteLine = line
    }
  }

  private func wordStarted(_ id: ObjectIdentifier, at time: Date) {
    guard utteranceIndex[id] != nil else { return }
    let first = min(wordTimes[id]?.first ?? time, time)
    let last = max(wordTimes[id]?.last ?? time, time)
    wordTimes[id] = (first, last)
  }

  private func utteranceEnded(_ id: ObjectIdentifier) {
    guard let index = utteranceIndex.removeValue(forKey: id) else { return }
    logMeasuredRate(script[index], times: wordTimes.removeValue(forKey: id))
    if index == currentIndex { currentFinished = true }
    outstanding = max(0, outstanding - 1)
    if outstanding == 0, stopKeepAliveAfterSpeech { endKeepAlive() }
  }

  /// Logs the speaking speed actually heard, in words per minute, from when the first and
  /// last words began (so pauses after the utterance don't count). Apple publishes no
  /// mapping from `rate` to words per minute, and it differs by voice, so this is how to
  /// check a setting. Short utterances are skipped as too noisy to measure.
  private func logMeasuredRate(_ segment: Segment, times: (first: Date, last: Date)?) {
    let words = segment.text.split(whereSeparator: \.isWhitespace).count
    guard let times, words >= 8 else { return }
    let seconds = times.last.timeIntervalSince(times.first)
    guard seconds > 1 else { return }
    let wpm = Int((Double(words - 1) / seconds * 60).rounded())
    let kind = segment.writeLine == nil ? "explanation" : "dictation"
    diag("audio", "measured \(wpm) words per minute (\(kind), rate \(String(format: "%.2f", segment.rate)))")
  }

  /// Explanation paragraphs between Write lines become one utterance each run; each Write
  /// line is dictated as below.
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
        result += dictation(line, cue: "Write.", inParts: dictateInParts)
      } else {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { prose.append(trimmed) }
      }
    }
    flushProse(beforeWrite: false)
    return result
  }

  /// The cue ("Write.") and the line, a little slower than explanations. In parts: one
  /// utterance per part (the cue leads the first), each followed by time to write that part.
  /// Otherwise: one utterance, then time to write the whole line.
  private func dictation(_ line: String, cue: String, slowdown: Float = 1, inParts: Bool) -> [Segment] {
    let speed = rate * Self.dictationRateFactor * slowdown
    let groups = Self.dictationGroups(line)
    nextLineID += 1
    guard inParts, !groups.isEmpty else {
      let pause = min(groups.map(Self.writingTime).reduce(0, +), Self.maxLinePause)
      return [
        Segment(
          text: cue + " " + line, rate: speed, pauseAfter: pause * writingTimeScale + Self.afterLinePause,
          writeLine: line, lineID: nextLineID)
      ]
    }
    return groups.enumerated().map { (index, group) -> Segment in
      let isLast = index == groups.count - 1
      return Segment(
        text: (index == 0 ? cue + " " : "") + group + (isLast ? "." : ","), rate: speed,
        pauseAfter: Self.writingTime(group) * writingTimeScale + (isLast ? Self.afterLinePause : 0),
        writeLine: line, lineID: nextLineID)
    }
  }

  /// The comma-separated chunks of a Write line, joined into parts of at most
  /// `maxGroupWords` spoken words. A part that writes nothing yet ("fraction, top") leads
  /// into the next chunk. Commas inside numbers ("1,000") don't split.
  static func dictationGroups(_ line: String) -> [String] {
    let chunks = line.replacingOccurrences(of: #",(?!\d)"#, with: "\n", options: .regularExpression)
      .components(separatedBy: "\n")
      .map { chunk in
        var chunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        while chunk.hasSuffix(".") { chunk.removeLast() }
        return chunk.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
    var groups: [String] = []
    var words = 0
    for chunk in chunks {
      let count = chunk.split(whereSeparator: \.isWhitespace).count
      if let last = groups.last, words + count <= maxGroupWords || writtenCharacters(last) == 0 {
        groups[groups.count - 1] = last + ", " + chunk
        words += count
      } else {
        groups.append(chunk)
        words = count
      }
    }
    return groups
  }

  /// Seconds to write a part by hand, before the writing-time setting.
  static func writingTime(_ group: String) -> TimeInterval {
    max(minGroupPause, secondsPerCharacter * Double(writtenCharacters(group)))
  }

  /// About how many characters a spoken part puts on paper: "cosine" is 3 (cos), "open
  /// paren" is 1, "fraction, top" is 0. A number counts its digits; any other word counts 1.
  static func writtenCharacters(_ text: String) -> Int {
    text.lowercased()
      .components(separatedBy: CharacterSet(charactersIn: ",.;:").union(.whitespacesAndNewlines))
      .filter { !$0.isEmpty }
      .reduce(0) { total, word in
        if let known = writtenWords[word] { return total + known }
        let digits = word.filter(\.isWholeNumber).count
        return total + (digits > 0 ? digits : 1)
      }
  }

  private static let writtenWords: [String: Int] = [
    "open": 0, "close": 0, "end": 0, "with": 0, "exponent": 0, "fraction": 0, "top": 0,
    "of": 0, "the": 0, "to": 0, "as": 0, "capital": 0, "square": 0, "natural": 0, "and": 0,
    "bottom": 1,
    "sine": 3, "cosine": 3, "tangent": 3, "secant": 3, "cosecant": 3, "cotangent": 3,
    "log": 2, "limit": 3, "inverse": 2,
  ]

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

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    let time = Date()
    Task { @MainActor in self.wordStarted(id, at: time) }
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
