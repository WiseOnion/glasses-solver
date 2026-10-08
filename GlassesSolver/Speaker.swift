import AVFoundation

/// Speaks text through the current audio route. When the glasses are connected to the
/// phone as Bluetooth audio (their normal state), that route is the glasses' speakers.
///
/// Speech flows the way iOS reads text normally: explanation text goes to the synthesizer as
/// whole utterances (its own sentence pauses sound natural; splitting sentences into separate
/// utterances made audible stop-start gaps), and everything is queued at once, with the
/// synthesizer's own `postUtteranceDelay` for pauses rather than app timers. Pen lines
/// ("Write:" starts a new line on paper and is announced "Start line N."; "Continue:" stays
/// on the same line; "Mark:" is crossing out or drawing a box) are dictated a little slower,
/// a few words at a time, with a pause after each part long enough to do it by hand (or, with
/// `dictateInParts` off, the whole line and then one pause). A line runs past the roughly two
/// seconds of speech that working memory holds, so writing it part by part is how dictation
/// is normally given. `repeatLastWriteLine()` says
/// the latest one again, slower each time it's asked for in a row, then carries on.
///
/// Also keeps the app running while an answer is pending with the phone locked: with the
/// `audio` background mode, iOS doesn't suspend an app that is playing audio, so a silent
/// loop covers the Claude call, and the spoken answer itself covers the rest.
@MainActor
final class Speaker: NSObject {
  /// Slider range for the speaking speed (AVSpeechUtterance rates run 0...1; 0.5 is iOS's default).
  static let rateRange: ClosedRange<Float> = 0.3...0.6
  /// Apple's own default speed. Voices are tuned for it; slower rates stretch the sound and
  /// make it flat and robotic. The writing pauses give the time to write, so the talking
  /// doesn't also need to be slow. Apple doesn't publish a rate-to-words mapping and it
  /// varies by voice, so the log reports the measured words per minute (see
  /// `logMeasuredRate`). See README, "How the voice dictates".
  static let defaultRate: Float = 0.5
  /// Slider range for the writing pause, as a multiple of the estimated writing time.
  static let writingTimeRange: ClosedRange<Double> = 0.5...2.5
  /// Dictation speed relative to `rate` (the same: see `defaultRate`), and the short beat
  /// before a Write line.
  private static let dictationRateFactor: Float = 1
  private static let beforeWritePause: TimeInterval = 0.4
  /// Each repeat of the same line in a row is this much slower, at most twice.
  private static let repeatRateFactor: Float = 0.9
  /// A dictated part puts at most this many marks on paper (a short piece to hold in mind
  /// while writing) and is at most this many spoken words. Words that only say where or
  /// how to write don't count as marks, so a part is a whole piece of math, and each part
  /// is one utterance: fewer, longer utterances keep the voice's natural intonation.
  private static let maxGroupMarks = 6
  private static let maxGroupWords = 16
  /// Writing time per character on paper (careful handwriting of math runs about one and a
  /// half characters a second), the least pause after a part, the most after a whole line,
  /// and a beat after a line to finish it and move the pen down.
  private static let secondsPerCharacter: TimeInterval = 0.7
  private static let minGroupPause: TimeInterval = 1.2
  private static let maxLinePause: TimeInterval = 20
  private static let afterLinePause: TimeInterval = 1
  /// Time for each thing a Mark line crosses out or draws, and the most for one Mark line.
  private static let markItemPause: TimeInterval = 2
  private static let maxMarkPause: TimeInterval = 8
  /// After "Problem 4.": time to find the spot on the paper and write the number.
  private static let problemPause: TimeInterval = 2

  var rate: Float = Speaker.defaultRate
  var writingTimeScale: Double = 1
  /// Pause to write after each part of a pen line (true), or after the whole line.
  var dictateInParts = true
  /// The chosen voice; nil means the best installed voice for the phone's language.
  var voiceIdentifier: String?
  /// The pen line most recently dictated, for `repeatLastWriteLine()`.
  private(set) var lastPenLine: PenLine?
  /// How many times in a row `lastPenLine` has been repeated.
  private var repeatCount = 0
  private var nextLineID = 0
  /// While an answer arrives in pieces: true until it's finished or stopped, the text of a
  /// line still arriving, explanation waiting for the next pen line, and the current line.
  private var answerOpen = false
  private var unfinishedLine = ""
  private var pendingProse: [String] = []
  private var lineNumber = 0

  /// An instruction to do something on paper, from a line tagged in the answer.
  struct PenLine: Equatable {
    enum Kind {
      /// "Write:" starts a new line on paper.
      case write
      /// "Sentence:" starts a new line and is words, not math symbols.
      case sentence
      /// "Continue:" keeps writing on the same line.
      case continueLine
      /// "Mark:" crosses out, draws a box, and so on.
      case mark
    }

    let kind: Kind
    let text: String
    /// The line on paper: Write lines count up from 1; the others keep the current number.
    let number: Int
  }

  private struct Segment {
    let text: String
    let rate: Float
    let pauseAfter: TimeInterval
    /// Set on every part of a dictated pen line.
    let penLine: PenLine?
    /// Shared by the parts of one dictated line.
    var lineID: Int?
    /// A voice for just this segment (voice comparison); nil uses the chosen voice.
    var voice: AVSpeechSynthesisVoice?
  }

  /// Called with the measured speaking speed (words a minute) of the next sentence spoken
  /// after `speak` or `compareVoices`, once; used to match a voice to a target speed.
  var measurementHandler: (@MainActor (Int) -> Void)?

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

  /// What's been queued since the last `speak`, `stop` or repeat, with the pause after
  /// each, for tests.
  var queued: [(text: String, pause: TimeInterval)] { script.map { ($0.text, $0.pauseAfter) } }

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
    answerOpen = false
    unfinishedLine = ""
    lastPenLine = nil
    repeatCount = 0
    let voice = resolvedVoice
    let voiceName = voice.map { $0.name + " (" + Self.qualityName($0.quality) + ")" } ?? "default"
    if chosenVoiceIsMissing, let id = voiceIdentifier {
      diag("audio", "the chosen voice \(id) isn't available to the app, so \(voiceName) is used instead")
    }
    diag(
      "audio",
      "speaking \(text.count) characters at rate \(rate), \(dictateInParts ? "dictating in parts" : "whole lines"), "
        + "voice \(voiceName), via \(Self.routeDescription)")
    enqueue(segments(for: text), voice: voice)
  }

  /// Says the latest pen line again, part by part and a little slower (slower again if
  /// asked twice in a row), then continues with whatever was left to say.
  @discardableResult
  func repeatLastWriteLine() -> Bool {
    guard let line = lastPenLine else { return false }
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
    diag("audio", "repeating the last pen line (\(repeatCount) in a row)")
    let again = repeatCount > 1 ? "Again, slower" : "Again"
    let cue = line.kind == .mark ? again + "." : again + ", line \(line.number)."
    enqueue(dictation(line, cue: cue, slowdown: slowdown, inParts: true) + remaining, voice: resolvedVoice)
    return true
  }

  func stop() {
    answerOpen = false
    reset()
    if stopKeepAliveAfterSpeech { endKeepAlive() }
  }

  // MARK: - Choosing a voice

  /// A real line of dictation (letters, a raised power, a fraction) for hearing a voice.
  static let comparisonLine =
    "y prime equals cosine of, open parenthesis, 3 x squared, close parenthesis, times a fraction, "
    + "on top, you have sine x, on the bottom, you have 2"

  /// A sentence of about 30 words, spoken to measure a voice's speed.
  static let calibrationText =
    "This is how fast the summary of the problem will sound. Next the voice dictates each line "
    + "to write, a few words at a time, and waits while you write each part."

  /// Voices iOS doesn't flag as novelty but that sound like it.
  private static let skippedInComparison: Set<String> = ["Grandma", "Grandpa", "Rocko"]

  /// The voices worth hearing side by side: the phone's exact language (such as en-US), best
  /// quality first, at most 12.
  static func comparisonVoices() -> [AVSpeechSynthesisVoice] {
    let code = AVSpeechSynthesisVoice.currentLanguageCode()
    let matching = availableVoices().filter { $0.language == code && !skippedInComparison.contains($0.name) }
    return Array((matching.isEmpty ? availableVoices() : matching).prefix(12))
  }

  /// Says the same real line of dictation in each voice, naming the voice first, at the
  /// current speed. The diagnostics log records each voice's measured words per minute.
  func compareVoices(_ voices: [AVSpeechSynthesisVoice]) {
    answerOpen = false
    reset()
    activateSession()
    lastPenLine = nil
    repeatCount = 0
    let line = PenLine(kind: .write, text: Self.comparisonLine, number: 1)
    let segments = voices.map { voice in
      Segment(
        text: "\(voice.name). \(Self.comparisonLine).", rate: rate * Self.dictationRateFactor,
        pauseAfter: 1.5, penLine: line, lineID: nil, voice: voice)
    }
    diag("audio", "comparing \(voices.count) voices: \(voices.map(\.name).joined(separator: ", "))")
    enqueue(segments, voice: nil)
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
    measurementHandler = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func enqueue(_ segments: [Segment], voice: AVSpeechSynthesisVoice?) {
    for segment in segments {
      let utterance = AVSpeechUtterance(string: segment.text)
      utterance.rate = segment.rate
      utterance.voice = segment.voice ?? voice
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
    if let line = script[index].penLine {
      if line != lastPenLine { repeatCount = 0 }
      lastPenLine = line
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
    let kind = segment.penLine == nil ? "explanation" : "dictation"
    let name = (segment.voice ?? resolvedVoice)?.name ?? "default voice"
    diag("audio", "measured \(wpm) words per minute (\(kind), \(name), rate \(String(format: "%.2f", segment.rate)))")
    if segment.penLine == nil, let handler = measurementHandler {
      measurementHandler = nil
      handler(wpm)
    }
  }

  // MARK: - An answer arriving in pieces

  /// Starts speaking an answer that arrives in pieces (`continueAnswer`), so the first
  /// problem is dictated while the rest is still being written. `finishAnswer` ends it.
  func beginAnswer() {
    speak("")
    answerOpen = true
  }

  /// Adds the next piece of the answer. Each line is spoken once it's complete.
  func continueAnswer(_ piece: String) {
    guard answerOpen else { return }  // stopped meanwhile
    unfinishedLine += piece
    guard let lastBreak = unfinishedLine.lastIndex(of: "\n") else { return }
    let complete = String(unfinishedLine[..<lastBreak])
    unfinishedLine = String(unfinishedLine[unfinishedLine.index(after: lastBreak)...])
    enqueue(complete.components(separatedBy: "\n").flatMap { segments(forParagraph: $0) }, voice: resolvedVoice)
  }

  /// Speaks the rest of the answer, then `notice` (such as `cutOffNotice`) if there is one.
  func finishAnswer(notice: String? = nil) {
    guard answerOpen else { return }
    answerOpen = false
    var rest = segments(forParagraph: unfinishedLine)
    unfinishedLine = ""
    if let notice {
      rest += flushProse(beforeWrite: true)
      rest.append(Segment(text: notice, rate: rate * Self.dictationRateFactor, pauseAfter: 0, penLine: nil))
    } else {
      rest += flushProse(beforeWrite: false)
    }
    enqueue(rest, voice: resolvedVoice)
  }

  /// Why an answer ended early.
  enum CutOff {
    /// It ran out of room (the answer length limit).
    case ranOut
    /// The connection dropped.
    case dropped
    /// Claude stopped answering partway.
    case stopped
  }

  /// What to say after an answer that ended early: that it did, where (the last problem
  /// started), and what to retake. The last line said may be unfinished.
  static func cutOffNotice(_ reason: CutOff, answer: String) -> String {
    let what =
      switch reason {
      case .ranOut: "The answer ran out of room"
      case .dropped: "The connection dropped"
      case .stopped: "The answer stopped"
      }
    let lastProblem = answer.components(separatedBy: "\n").compactMap(problemLabel(in:)).last
    guard let lastProblem else {
      return "Stop. \(what) before the first problem. Take the photo again."
    }
    return "Stop. \(what) partway through problem \(lastProblem), so its last line may be unfinished. "
      + "Take a new photo of problem \(lastProblem) and any after it."
  }

  // MARK: - Turning an answer into speech

  /// Other paragraphs between pen lines become one utterance each run; each pen line is
  /// dictated as below. A "Problem:" line is announced and starts the line count over.
  private func segments(for text: String) -> [Segment] {
    pendingProse.removeAll()
    lineNumber = 0
    return text.components(separatedBy: "\n").flatMap { segments(forParagraph: $0) }
      + flushProse(beforeWrite: false)
  }

  /// The speech for one paragraph of an answer. Explanation paragraphs wait in
  /// `pendingProse` until a pen line or problem comes, so a run of them is one utterance.
  private func segments(forParagraph raw: String) -> [Segment] {
    let paragraph = Self.speakable(raw)
    if let label = Self.problemLabel(in: paragraph) {
      lineNumber = 0
      return flushProse(beforeWrite: true)
        + [Segment(text: "Problem \(label).", rate: rate, pauseAfter: Self.problemPause, penLine: nil)]
    }
    if let pen = Self.penLine(in: paragraph) {
      if pen.0 == .write || pen.0 == .sentence { lineNumber += 1 }
      let line = PenLine(kind: pen.0, text: pen.1, number: max(lineNumber, 1))
      return flushProse(beforeWrite: true) + dictation(line, cue: Self.cue(for: line), inParts: dictateInParts)
    }
    if !paragraph.isEmpty { pendingProse.append(paragraph) }
    return []
  }

  private func flushProse(beforeWrite: Bool) -> [Segment] {
    guard !pendingProse.isEmpty else { return [] }
    let joined = pendingProse.map { line in
      line.last.map { ".!?:;".contains($0) } == true ? line : line + "."
    }.joined(separator: " ")
    pendingProse.removeAll()
    return [Segment(text: joined, rate: rate, pauseAfter: beforeWrite ? Self.beforeWritePause : 0, penLine: nil)]
  }

  /// What's said before a pen line: where on the paper it goes. A Mark line says it itself,
  /// and so does a Continue line that starts with where it goes ("on the bottom, ...").
  static func cue(for line: PenLine) -> String {
    switch line.kind {
    case .write, .sentence: "Start line \(line.number)."
    case .continueLine:
      line.text.lowercased().hasPrefix("on the bottom") || line.text.lowercased().hasPrefix("on top")
        ? "" : "Same line."
    case .mark: ""
    }
  }

  /// The cue and the line, a little slower than explanations. In parts: one utterance per
  /// part (the cue leads the first), each followed by time to write that part. Otherwise: one
  /// utterance, then time for the whole line. A Mark line is always one utterance, since the
  /// whole location has to be heard before crossing anything out.
  private func dictation(_ line: PenLine, cue: String, slowdown: Float = 1, inParts: Bool) -> [Segment] {
    let speed = rate * Self.dictationRateFactor * slowdown
    let lead = cue.isEmpty ? "" : cue + " "
    nextLineID += 1
    let lineID = nextLineID
    if line.kind == .mark {
      return [
        Segment(
          text: lead + line.text, rate: speed,
          pauseAfter: Self.markPause(line.text) * writingTimeScale + Self.afterLinePause,
          penLine: line, lineID: lineID)
      ]
    }
    let groups = Self.dictationGroups(line.text)
    let writingTime = line.kind == .sentence ? Self.sentenceWritingTime : Self.writingTime
    guard inParts, !groups.isEmpty else {
      let pause = min(groups.map(writingTime).reduce(0, +), Self.maxLinePause)
      return [
        Segment(
          text: lead + line.text, rate: speed, pauseAfter: pause * writingTimeScale + Self.afterLinePause,
          penLine: line, lineID: lineID)
      ]
    }
    return groups.enumerated().map { (index, group) -> Segment in
      let isLast = index == groups.count - 1
      return Segment(
        text: (index == 0 ? lead : "") + group + (isLast ? "." : ","), rate: speed,
        pauseAfter: writingTime(group) * writingTimeScale + (isLast ? Self.afterLinePause : 0),
        penLine: line, lineID: lineID)
    }
  }

  /// Seconds for a Mark line, before the writing-time setting: 2 for each thing to cross out
  /// or draw (one, plus one per "and"), at most 8.
  static func markPause(_ text: String) -> TimeInterval {
    let items = text.lowercased().components(separatedBy: " and ").count
    return min(markItemPause * Double(items), maxMarkPause)
  }

  /// The label after "Problem:" ("4", "number 7") if this paragraph starts a problem.
  static func problemLabel(in paragraph: String) -> String? {
    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("problem:") else { return nil }
    var label = trimmed.dropFirst("problem:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    while label.hasSuffix(".") { label.removeLast() }
    // "part a" is read as the letter, not "uh".
    if let range = label.range(of: #"(?<=[Pp]art )[a-z]\b"#, options: .regularExpression) {
      label.replaceSubrange(range, with: label[range].uppercased())
    }
    return label.isEmpty ? nil : label
  }

  /// The comma-separated chunks of a Write line, joined into parts that each put at most
  /// `maxGroupMarks` marks on paper (and at most `maxGroupWords` spoken words), so a part is
  /// a whole piece of math however many words it takes to say. Words that only say where
  /// to write ("right beside that", "on top") lead into what follows; a shape description
  /// ("a small tick at the top right") or a power ("squared", "to the 4th") stays with
  /// the mark before it. Commas inside numbers ("1,000") don't split.
  static func dictationGroups(_ line: String) -> [String] {
    let chunks = line.replacingOccurrences(of: #",(?!\d)"#, with: "\n", options: .regularExpression)
      .components(separatedBy: "\n")
      .map { chunk in
        var chunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        while chunk.hasSuffix(".") { chunk.removeLast() }
        return chunk.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
    // Units that are never split: a mark with whatever leads into it or belongs to it.
    var units: [String] = []
    var leading: String?
    for chunk in chunks {
      let lowered = chunk.lowercased()
      let belongsBefore = ["a ", "raised to the power", "squared", "cubed", "to the "].contains { lowered.hasPrefix($0) }
      if leading == nil, belongsBefore, let last = units.last {
        units[units.count - 1] = last + ", " + chunk
        continue
      }
      let text = leading.map { $0 + ", " + chunk } ?? chunk
      leading = nil
      if writtenCharacters(text) == 0 {
        leading = text
      } else {
        units.append(text)
      }
    }
    if let leading {
      if let last = units.last { units[units.count - 1] = last + ", " + leading } else { units.append(leading) }
    }
    var groups: [String] = []
    for unit in units {
      if let last = groups.last {
        let joined = last + ", " + unit
        if writtenCharacters(joined) <= maxGroupMarks,
          joined.split(whereSeparator: \.isWhitespace).count <= maxGroupWords
        {
          groups[groups.count - 1] = joined
          continue
        }
      }
      groups.append(unit)
    }
    return groups
  }

  /// Seconds to write a part by hand, before the writing-time setting.
  static func writingTime(_ group: String) -> TimeInterval {
    max(minGroupPause, secondsPerCharacter * Double(writtenCharacters(group)))
  }

  /// Seconds to write a part of a sentence: every letter and digit counts, "period" or "comma"
  /// counts one, and "capital" (the next word starts with a capital) counts none.
  static func sentenceWritingTime(_ group: String) -> TimeInterval {
    let words = group.lowercased()
      .components(separatedBy: CharacterSet(charactersIn: ",.;:").union(.whitespacesAndNewlines))
      .filter { !$0.isEmpty }
    var characters = 0
    for word in words {
      if word == "capital" { continue }  // says the next word starts with a capital
      if word == "period" || word == "comma" {
        characters += 1
      } else {
        characters += word.filter { $0.isLetter || $0.isWholeNumber }.count
      }
    }
    return max(minGroupPause, secondsPerCharacter * Double(characters))
  }

  /// About how many characters a spoken part puts on paper: "the letters c o s" is 3,
  /// "open parenthesis" is 1, "small raised 2" is 1, "start fraction, on top" is 0. A number
  /// counts its digits; any other word counts 1, except words that only say where or how
  /// to write, which count 0.
  static func writtenCharacters(_ text: String) -> Int {
    // Commas are kept as words of their own, since a spelling ends at one.
    let words = text.lowercased().replacingOccurrences(of: ",", with: " , ")
      .components(separatedBy: CharacterSet(charactersIn: ".;:").union(.whitespacesAndNewlines))
      .filter { !$0.isEmpty }
    var total = 0
    // True while spelling: after "letters", until a comma or a word that isn't one letter.
    var spelling = false
    for (index, word) in words.enumerated() {
      spelling = word == "letters" || (spelling && word.count == 1 && word.first!.isLetter)
      if word == "," { continue }
      // "a" starts a shape description ("a small tick"); only "letter a" and an a being
      // spelled ("the letters t a n") are marks.
      if word == "a" {
        if spelling || (index > 0 && words[index - 1] == "letter") { total += 1 }
        continue
      }
      if let known = writtenWords[word] {
        total += known
        continue
      }
      let digits = word.filter(\.isWholeNumber).count
      total += digits > 0 ? digits : 1
    }
    return total
  }

  private static let writtenWords: [String: Int] = [
    "open": 0, "close": 0, "end": 0, "with": 0, "exponent": 0, "fraction": 0, "top": 0,
    "of": 0, "the": 0, "to": 0, "as": 0, "capital": 0, "square": 0, "natural": 0, "and": 0,
    "start": 0, "small": 0, "raised": 0, "under": 0, "on": 0, "at": 0, "then": 0,
    "them": 0, "letters": 0, "letter": 0, "sign": 0, "mark": 0, "marks": 0, "bar": 0,
    "line": 0, "right": 0, "left": 0, "pointing": 0, "middle": 0, "height": 0, "check": 0,
    "short": 0, "across": 0, "sideways": 0, "tick": 0, "dot": 0, "back": 0, "down": 0,
    "tiny": 0, "lowered": 0, "up": 0, "root": 0, "notch": 0, "tucked": 0, "in": 0, "its": 0,
    "an": 0, "power": 0, "beside": 0, "next": 0, "that": 0, "previous": 0, "thing": 0, "it": 0,
    "below": 0, "underneath": 0, "you": 0, "have": 0, "base": 0,
    "bottom": 1, "draw": 1, "over": 1,
    "sine": 3, "cosine": 3, "tangent": 3, "secant": 3, "cosecant": 3, "cotangent": 3,
    "log": 2, "limit": 3, "inverse": 2,
  ]

  private static let penTags: [(tag: String, kind: PenLine.Kind)] = [
    ("write:", .write), ("sentence:", .sentence), ("continue:", .continueLine), ("mark:", .mark),
  ]

  /// The kind and text of a pen line ("Write:", "Continue:" or "Mark:"), if this paragraph is
  /// one. "letter a" becomes "letter A", and the a in "the letters t a n" becomes A, which
  /// voices say as the letter rather than "uh".
  static func penLine(in paragraph: String) -> (PenLine.Kind, String)? {
    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    guard let match = penTags.first(where: { lowered.hasPrefix($0.tag) }) else { return nil }
    let text = trimmed.dropFirst(match.tag.count).trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\b([Ll]etter) a\b"#, with: "$1 A", options: .regularExpression)
      .replacingOccurrences(
        of: #"(?<=\b[Ll]etters(?: [a-zA-Z]){0,8}) a\b"#, with: " A", options: .regularExpression)
    return text.isEmpty ? nil : (match.kind, text)
  }

  // MARK: - Voices

  /// Installed voices in the phone's language, best quality first. Novelty and Personal
  /// Voice voices are left out.
  /// Every installed voice except novelty and Personal Voice ones, with the phone's
  /// language first, then best quality, then by name. Voices from other apps (such as
  /// Piper) are included: they can report languages like "en" or "en_US", so nothing is
  /// filtered out by language.
  static func availableVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
      .sorted { a, b in
        let aLocal = isPhoneLanguage(a.language)
        let bLocal = isPhoneLanguage(b.language)
        if aLocal != bLocal { return aLocal }
        if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
        return a.name < b.name
      }
  }

  /// "en", "en-US", "en_GB" all count as English on an English phone.
  static func isPhoneLanguage(_ language: String) -> Bool {
    let phone = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2)).lowercased()
    return language.lowercased().hasPrefix(phone)
  }

  /// True for voices installed by another app rather than by iOS.
  static func isFromOtherApp(_ voice: AVSpeechSynthesisVoice) -> Bool {
    !voice.identifier.hasPrefix("com.apple.")
  }

  /// The best installed voice for the phone's exact language (e.g. en-US), then any variant.
  static var bestVoice: AVSpeechSynthesisVoice? {
    let code = AVSpeechSynthesisVoice.currentLanguageCode()
    let voices = availableVoices()
    return voices.first { $0.language == code }
      ?? voices.first { isPhoneLanguage($0.language) }
      ?? AVSpeechSynthesisVoice(language: code)
  }

  /// The chosen voice if it's still installed, otherwise the best one.
  var resolvedVoice: AVSpeechSynthesisVoice? {
    chosenVoice ?? Self.bestVoice
  }

  /// The voice picked in Settings, looked up by identifier directly and then in the list of
  /// installed voices (a voice from another app may only turn up there).
  private var chosenVoice: AVSpeechSynthesisVoice? {
    guard let id = voiceIdentifier else { return nil }
    return AVSpeechSynthesisVoice(identifier: id)
      ?? AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == id }
  }

  /// True when a voice was picked but iOS can't find it, so the automatic voice is used.
  var chosenVoiceIsMissing: Bool {
    voiceIdentifier != nil && chosenVoice == nil
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
