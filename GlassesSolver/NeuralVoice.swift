import AVFoundation
import Foundation

@preconcurrency import SherpaOnnx

/// Plays answers in a natural voice that iOS doesn't provide, from one of two sources:
///
/// - **Azure** (online): Microsoft's neural voices, through the Speech REST API with the
///   user's own key. A whole pen line goes in one request, with its writing pauses inside it
///   as SSML breaks, so it's one smooth, connected utterance rather than pieces glued
///   together (short separate pieces sounded smeared and uneven). The free tier is 500,000
///   characters a month, about 600 answers.
/// - **Heart** (built in, offline): Kokoro's best-rated voice, run by sherpa-onnx. The voice
///   files are added by the build (see .github/workflows/build-ipa.yml). Used when there's
///   no Azure key, and when Azure can't be reached.
///
/// Speaker hands it the same pieces it would give Apple's voice. Making speech runs ahead of
/// playing it, up to `maxAhead` clips, including during writing pauses, so the next clip is
/// ready when the one before it ends. Each clip is played followed by its last writing pause
/// as silence, so the audio never stops, and the app keeps running with the phone locked
/// (the audio background mode).
@MainActor
final class NeuralVoice {
  nonisolated static let voiceName = "Heart"
  /// Heart's place in Kokoro v1.0's voice table.
  nonisolated static let speakerID = 3

  /// Where the build puts the Heart voice files.
  private static var folder: URL {
    (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
      .appendingPathComponent("Voices/kokoro", isDirectory: true)
  }

  /// True when this build includes the Heart voice files.
  static var isBundled: Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.int8.onnx").path)
  }

  /// The voice's speed for a speaking rate on Apple's scale (0.5 is the default). Natural
  /// voices at their own speed (about 150 words a minute) were far too fast to copy from, so
  /// the default is slower: 0.85 for sentences, and 0.8 for pen lines, which are being
  /// written down. Not slower than that: listening studies find that slowing speech itself
  /// doesn't help understanding, while pauses at phrase boundaries do (the writing pauses),
  /// and very slow speech sounds drawn out. The speed slider scales both.
  static func speed(forRate rate: Float, penLine: Bool) -> Float {
    let base: Float = penLine ? 0.8 : 0.85
    return min(max(base * rate / 0.5, 0.45), 1.3)
  }

  /// An Azure voice and the key and region to reach it.
  struct AzureVoice: Sendable, Equatable {
    let key: String
    /// Such as "eastus".
    let region: String
    /// Such as "en-US-AvaMultilingualNeural".
    let voice: String
  }

  /// Use Azure when set (and reachable); Heart otherwise.
  var azure: AzureVoice?

  /// While true, playback is paused where it is (clips keep being made); set false to carry on.
  /// `stop` leaves it as it is, so speech queued during a hold waits too.
  var held = false {
    didSet {
      guard held != oldValue else { return }
      if held {
        player.pause()
      } else if playing {
        resumePlayback()
      }
    }
  }

  /// One piece to say, then a pause. `token` comes back in `onStart` and `onEnd`. Pieces with
  /// the same `group` (one pen line) are said in one Azure request.
  struct Item: Sendable {
    let text: String
    let speed: Float
    let pauseAfter: TimeInterval
    let token: Int
    var group: Int?
  }

  /// Called as each piece starts and finishes playing (its pause included).
  var onStart: ((Int) -> Void)?
  var onEnd: ((Int) -> Void)?
  /// Called with the tokens not yet finished if no natural voice can run, so they can be
  /// said another way.
  var onFailure: (([Int]) -> Void)?

  fileprivate struct Audio: Sendable {
    let samples: [Float]
    let sampleRate: Int
  }

  /// Makes Heart's speech on background threads, one piece at a time.
  private final class Engine: @unchecked Sendable {
    private let lock = NSLock()
    private var tts: SherpaOnnxOfflineTtsWrapper?

    func load(folder: URL) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if tts != nil { return true }
      func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
      let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
        model: path("model.int8.onnx"),
        voices: path("voices.bin"),
        tokens: path("tokens.txt"),
        dataDir: path("espeak-ng-data"),
        lexicon: path("lexicon-us-en.txt"))
      let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2)
      var config = sherpaOnnxOfflineTtsConfig(model: model)
      let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
      guard wrapper.tts != nil else { return false }
      tts = wrapper
      return true
    }

    func synthesize(_ text: String, speed: Float) -> Audio {
      lock.lock()
      defer { lock.unlock() }
      guard let tts else { return Audio(samples: [], sampleRate: 0) }
      var config = SherpaOnnxGenerationConfigSwift()
      config.sid = NeuralVoice.speakerID
      config.speed = speed
      let audio = tts.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
      return Audio(samples: audio.samples, sampleRate: Int(audio.sampleRate))
    }
  }

  private let engine = Engine()
  private var loading: Task<Bool, Never>?
  /// Pieces not made yet, and clips made and waiting to play, in order.
  private var pending: [Item] = []
  private var ready: [(items: [Item], audio: Audio)] = []
  /// At most this many clips are made ahead of the one playing.
  private static let maxAhead = 6
  /// After Azure fails, Heart is used for this long before trying Azure again.
  private static let azureRetryDelay: TimeInterval = 120
  private var azureFailedAt: Date?
  private var producing = false
  private var playing = false
  /// Wakes the player when a clip is ready (or making stops).
  private var readySignal: Waiter?
  /// Bumped by `stop`, so work from before it is dropped.
  private var generation = 0
  private let audioEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var connectedRate = 0
  /// Ends the wait for the clip playing now.
  private var finishPlaying: Waiter?

  /// Resumes a wait once, from whichever thread finishes first (playback or `stop`).
  private final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func finish() {
      lock.lock()
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume()
    }
  }
  private var configurationObserver: NSObjectProtocol?

  init() {
    audioEngine.attach(player)
    // A route change (glasses connecting, for example) stops the engine; start it again.
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.restartAfterRouteChange() }
    }
  }

  /// Loads Heart in the background (a few seconds the first time), once.
  @discardableResult
  func preload() -> Task<Bool, Never> {
    if let loading { return loading }
    let engine = self.engine
    let folder = Self.folder
    let task = Task.detached(priority: .userInitiated) { () -> Bool in
      let started = Date()
      let ok = Self.isBundledAt(folder) && engine.load(folder: folder)
      let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
      diag("neural", ok ? "Kokoro \(NeuralVoice.voiceName) loaded in \(seconds) seconds" : "couldn't load Kokoro from \(folder.path)")
      return ok
    }
    loading = task
    return task
  }

  private nonisolated static func isBundledAt(_ folder: URL) -> Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.int8.onnx").path)
  }

  /// Adds pieces to say after whatever is already queued.
  func speak(_ items: [Item]) {
    pending += items
    startProducing()
    startPlaying()
  }

  /// Stops at once and forgets everything queued.
  func stop() {
    generation += 1
    pending.removeAll()
    ready.removeAll()
    producing = false
    playing = false
    // Also when paused (a hold), so the old clip is dropped rather than played on release.
    if connectedRate != 0 { player.stop() }
    finishPlaying?.finish()
    finishPlaying = nil
    wakePlayer()
  }

  private func startProducing() {
    guard !producing, !pending.isEmpty else { return }
    producing = true
    let current = generation
    Task { await produce(generation: current) }
  }

  private func startPlaying() {
    guard !playing else { return }
    playing = true
    let current = generation
    Task { await playAll(generation: current) }
  }

  private func wakePlayer() {
    readySignal?.finish()
    readySignal = nil
  }

  /// The Azure voice to use now: set, and not failed in the last `azureRetryDelay`.
  private var activeAzure: AzureVoice? {
    guard let azure else { return nil }
    if let failed = azureFailedAt, Date().timeIntervalSince(failed) < Self.azureRetryDelay { return nil }
    return azure
  }

  /// Makes pending pieces into clips one after another, staying at most `maxAhead` ahead of
  /// playback: a whole pen line per clip with Azure, one piece per clip with Heart.
  private func produce(generation current: Int) async {
    while current == generation, !pending.isEmpty, ready.count < Self.maxAhead {
      if let azure = activeAzure {
        let items = takeGroup()
        do {
          let audio = try await Self.synthesizeWithAzure(items, voice: azure)
          guard current == generation else { return }
          ready.append((items, audio))
          wakePlayer()
          continue
        } catch {
          guard current == generation else { return }
          diag("neural", "Azure voice failed, using Heart for now: \(ErrorDetail.describe(error))")
          azureFailedAt = Date()
          pending.insert(contentsOf: items, at: 0)
        }
      }
      guard await preload().value else {
        guard current == generation else { return }
        let tokens = ready.flatMap { $0.items.map(\.token) } + pending.map(\.token)
        ready.removeAll()
        pending.removeAll()
        producing = false
        wakePlayer()
        onFailure?(tokens)
        return
      }
      guard current == generation, !pending.isEmpty else { break }
      let item = pending.removeFirst()
      let engine = self.engine
      let audio = await Task.detached(priority: .userInitiated) {
        engine.synthesize(item.text, speed: item.speed)
      }.value
      guard current == generation else { return }
      ready.append(([item], audio))
      wakePlayer()
    }
    if current == generation {
      producing = false
      wakePlayer()
    }
  }

  /// The first pending piece and any after it in the same group (one pen line).
  private func takeGroup() -> [Item] {
    let first = pending.removeFirst()
    var items = [first]
    while let group = first.group, let next = pending.first, next.group == group, items.count < 16 {
      items.append(pending.removeFirst())
    }
    return items
  }

  /// Plays ready clips in order, waiting only when the next one isn't made yet.
  private func playAll(generation current: Int) async {
    while current == generation {
      guard !ready.isEmpty else {
        if pending.isEmpty && !producing { break }
        let started = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          readySignal = Waiter(continuation)
        }
        guard current == generation else { return }
        logWait(Date().timeIntervalSince(started), next: ready.first?.items.first)
        continue
      }
      let (items, audio) = ready.removeFirst()
      startProducing()
      onStart?(items[0].token)
      await play(audio, pauseAfter: items.last?.pauseAfter ?? 0)
      guard current == generation else { return }
      // A clip holding several pieces reports each, in order, so Speaker's count stays right.
      for (index, item) in items.enumerated() {
        if index > 0 { onStart?(item.token) }
        onEnd?(item.token)
      }
    }
    if current == generation { playing = false }
  }

  /// Logs a wait for the next clip (dead air), so a slow phone or network shows up in the
  /// diagnostics.
  private func logWait(_ waited: TimeInterval, next: Item?) {
    guard waited > 0.3, let next else { return }
    diag("neural", "waited \(String(format: "%.1f", waited)) s for the next piece: \"\(next.text.prefix(40))\"")
  }

  // MARK: - Azure

  enum AzureError: LocalizedError {
    case http(Int)
    case badAudio

    var errorDescription: String? {
      switch self {
      case .http(401): "the Azure key or region was rejected"
      case .http(let status): "Azure answered \(status)"
      case .badAudio: "Azure sent no audio"
      }
    }
  }

  /// SSML for one clip: the pieces in order, each followed by its writing pause as a break,
  /// except the last (its pause is played as silence after the clip), at the pieces' speed.
  nonisolated static func ssml(for items: [Item], voice: String) -> String {
    let rate = Int(((items.first?.speed ?? 1) - 1) * 100)
    var body = ""
    for (index, item) in items.enumerated() {
      body += escapeXML(item.text)
      if index < items.count - 1 {
        // A break is at most 20 seconds; longer pauses are several breaks.
        var pause = Int((item.pauseAfter * 1000).rounded())
        while pause > 0 {
          body += "<break time=\"\(min(pause, 20000))ms\"/>"
          pause -= 20000
        }
        body += " "
      }
    }
    // Each comma is a short breath of the same length (MathCAT's short pause, 200 ms at 180
    // words a minute, made longer as the voice is slowed), so the commas that group the math
    // sound alike rather than varying with the voice's own phrasing.
    let comma = Int((commaPause / Double(items.first?.speed ?? 1) * 1000).rounded())
    return "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" "
      + "xmlns:mstts=\"http://www.w3.org/2001/mstts\" xml:lang=\"en-US\">"
      + "<voice name=\"\(escapeXML(voice))\"><mstts:silence type=\"comma-exact\" value=\"\(comma)ms\"/>"
      + "<prosody rate=\"\(rate)%\">\(body)</prosody></voice></speak>"
  }

  /// The breath at a comma at the voice's own speed, in seconds.
  nonisolated static let commaPause: TimeInterval = 0.2

  nonisolated static func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  private nonisolated static func synthesizeWithAzure(_ items: [Item], voice: AzureVoice) async throws -> Audio {
    let region = voice.region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
      throw AzureError.http(400)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue(voice.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
    request.setValue("raw-24khz-16bit-mono-pcm", forHTTPHeaderField: "X-Microsoft-OutputFormat")
    request.setValue("GlassesSolver", forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(ssml(for: items, voice: voice.voice).utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw AzureError.http(status) }
    guard data.count >= 2 else { throw AzureError.badAudio }
    // 16-bit little-endian samples.
    let samples = data.withUnsafeBytes { raw -> [Float] in
      let values = raw.bindMemory(to: Int16.self)
      return values.map { Float(Int16(littleEndian: $0)) / 32768 }
    }
    return Audio(samples: samples, sampleRate: 24000)
  }

  // MARK: - Playing

  /// Plays the speech and then the pause as silence, and returns when both are done (or
  /// when stopped).
  private func play(_ audio: Audio, pauseAfter: TimeInterval) async {
    guard audio.sampleRate > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate), channels: 1, interleaved: false)
    else { return }
    let silence = Int(pauseAfter * Double(audio.sampleRate))
    let frames = audio.samples.count + silence
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    if let channel = buffer.floatChannelData?[0] {
      audio.samples.withUnsafeBufferPointer { source in
        if let base = source.baseAddress { channel.update(from: base, count: source.count) }
      }
      (channel + audio.samples.count).initialize(repeating: 0, count: silence)
    }
    guard startEngine(format: format) else { return }
    var waiterForThisClip: Waiter?
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let waiter = Waiter(continuation)
      waiterForThisClip = waiter
      finishPlaying = waiter
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in waiter.finish() }
      if !player.isPlaying && !held { player.play() }
    }
    // Only its own wait: a `stop` and a new clip may have replaced it meanwhile.
    if finishPlaying === waiterForThisClip { finishPlaying = nil }
  }

  private func startEngine(format: AVAudioFormat) -> Bool {
    if connectedRate != Int(format.sampleRate) {
      audioEngine.disconnectNodeOutput(player)
      audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
      connectedRate = Int(format.sampleRate)
    }
    guard !audioEngine.isRunning else { return true }
    do {
      try audioEngine.start()
      return true
    } catch {
      diag("neural", "audio engine couldn't start: \(ErrorDetail.describe(error))")
      return false
    }
  }

  /// Starts playing again after a call or Siri stopped the audio, unless held.
  func resumeAfterInterruption() {
    guard playing, !held else { return }
    diag("neural", "starting the voice again after an interruption")
    resumePlayback()
  }

  private func resumePlayback() {
    do {
      if !audioEngine.isRunning { try audioEngine.start() }
      player.play()
    } catch {
      diag("neural", "audio engine couldn't restart: \(ErrorDetail.describe(error))")
      finishPlaying?.finish()
    }
  }

  private func restartAfterRouteChange() {
    guard playing, !audioEngine.isRunning else { return }
    diag("neural", "audio route changed; starting the voice again\(held ? " (held, so not playing yet)" : "")")
    do {
      try audioEngine.start()
      if !held { player.play() }
    } catch {
      diag("neural", "audio engine couldn't restart: \(ErrorDetail.describe(error))")
      // Let the current clip finish so the rest isn't stuck waiting.
      finishPlaying?.finish()
    }
  }
}
