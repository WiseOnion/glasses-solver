import AVFoundation
import Foundation

@preconcurrency import SherpaOnnx

/// The built-in neural voice: Kokoro's "Heart" (grade A, its best-rated voice), run inside
/// the app by sherpa-onnx, so it works offline and doesn't depend on iOS handing over other
/// apps' voices (iOS 26 doesn't, reliably). The voice files are added to the app by the build
/// (see .github/workflows/build-ipa.yml) rather than stored in the repo.
///
/// Speaker hands it the same pieces it would give Apple's voice. Making speech runs ahead of
/// playing it: pieces are made one after another on a background thread, up to `maxAhead`
/// pieces ahead, including during writing pauses, so a piece is ready when the one before it
/// ends and there's no dead air between sentences. Each piece is played followed by its
/// writing pause as silence, so the audio never stops, and the app keeps running with the
/// phone locked (the audio background mode).
@MainActor
final class NeuralVoice {
  nonisolated static let voiceName = "Heart"
  /// Heart's place in Kokoro v1.0's voice table.
  nonisolated static let speakerID = 3

  /// Where the build puts the voice files.
  private static var folder: URL {
    (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
      .appendingPathComponent("Voices/kokoro", isDirectory: true)
  }

  /// True when this build includes the voice files.
  static var isBundled: Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.int8.onnx").path)
  }

  /// Kokoro's speed for a speaking rate on Apple's scale (0.5 is the default). Heart's own
  /// speed (1) is about 150 words a minute, which the user found far too fast, so the
  /// default is slower: 0.85 for sentences, and 0.7 for pen lines, which are being written
  /// down. Unlike Apple's voices, Kokoro sounds natural slowed down: it speaks slower rather
  /// than stretching the sound. The speed slider scales both.
  static func speed(forRate rate: Float, penLine: Bool) -> Float {
    let base: Float = penLine ? 0.7 : 0.85
    return min(max(base * rate / 0.5, 0.45), 1.3)
  }

  /// One piece to say, then a pause. `token` comes back in `onStart` and `onEnd`.
  struct Item: Sendable {
    let text: String
    let speed: Float
    let pauseAfter: TimeInterval
    let token: Int
  }

  /// Called as each piece starts and finishes playing (its pause included).
  var onStart: ((Int) -> Void)?
  var onEnd: ((Int) -> Void)?
  /// Called with the tokens not yet finished if the voice can't run, so they can be said
  /// another way.
  var onFailure: (([Int]) -> Void)?

  private struct Audio: Sendable {
    let samples: [Float]
    let sampleRate: Int
  }

  /// Makes speech on background threads, one piece at a time.
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
  /// Pieces not made yet, and pieces made and waiting to play, in order.
  private var pending: [Item] = []
  private var ready: [(item: Item, audio: Audio)] = []
  /// At most this many pieces are made ahead of the one playing.
  private static let maxAhead = 6
  private var producing = false
  private var playing = false
  /// Wakes the player when a piece is ready (or making stops).
  private var readySignal: Waiter?
  /// Bumped by `stop`, so work from before it is dropped.
  private var generation = 0
  private let audioEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var connectedRate = 0
  /// Ends the wait for the piece playing now.
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

  /// Loads the voice in the background (a few seconds the first time), once.
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
    if player.isPlaying { player.stop() }
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

  /// Makes pending pieces one after another, staying at most `maxAhead` ahead of playback.
  private func produce(generation current: Int) async {
    guard await preload().value else {
      guard current == generation else { return }
      let tokens = ready.map(\.item.token) + pending.map(\.token)
      ready.removeAll()
      pending.removeAll()
      producing = false
      wakePlayer()
      onFailure?(tokens)
      return
    }
    while current == generation, !pending.isEmpty, ready.count < Self.maxAhead {
      let item = pending.removeFirst()
      let engine = self.engine
      let audio = await Task.detached(priority: .userInitiated) {
        engine.synthesize(item.text, speed: item.speed)
      }.value
      guard current == generation else { return }
      ready.append((item, audio))
      wakePlayer()
    }
    if current == generation {
      producing = false
      wakePlayer()
    }
  }

  /// Plays ready pieces in order, waiting only when the next one isn't made yet.
  private func playAll(generation current: Int) async {
    while current == generation {
      guard !ready.isEmpty else {
        if pending.isEmpty && !producing { break }
        let started = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          readySignal = Waiter(continuation)
        }
        guard current == generation else { return }
        logWait(Date().timeIntervalSince(started), next: ready.first?.item)
        continue
      }
      let (item, audio) = ready.removeFirst()
      startProducing()
      onStart?(item.token)
      await play(audio, pauseAfter: item.pauseAfter)
      guard current == generation else { return }
      onEnd?(item.token)
    }
    if current == generation { playing = false }
  }

  /// Logs a wait for the next piece (dead air), so a slow phone shows up in the diagnostics.
  private func logWait(_ waited: TimeInterval, next: Item?) {
    guard waited > 0.3, let next else { return }
    diag("neural", "waited \(String(format: "%.1f", waited)) s for the next piece: \"\(next.text.prefix(40))\"")
  }

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
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let waiter = Waiter(continuation)
      finishPlaying = waiter
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in waiter.finish() }
      if !player.isPlaying { player.play() }
    }
    finishPlaying = nil
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

  private func restartAfterRouteChange() {
    guard playing, !audioEngine.isRunning else { return }
    diag("neural", "audio route changed; starting the voice again")
    do {
      try audioEngine.start()
      player.play()
    } catch {
      diag("neural", "audio engine couldn't restart: \(ErrorDetail.describe(error))")
      // Let the current piece finish so the rest isn't stuck waiting.
      finishPlaying?.finish()
    }
  }
}
