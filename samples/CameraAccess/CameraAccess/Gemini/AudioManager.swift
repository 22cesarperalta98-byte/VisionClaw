import AVFoundation
import AudioToolbox
import Foundation
import UIKit

class AudioManager {
  var onAudioCaptured: ((Data) -> Void)?

  // Rebuilt fresh on every capture start: enabling voice processing swaps the
  // IO unit, and doing that to a long-lived engine -- or stopping and
  // restarting one -- is how the input node ends up reporting 0 Hz and the tap
  // never fires. A new engine each time makes the setup order deterministic.
  private var audioEngine = AVAudioEngine()
  private var playerNode = AVAudioPlayerNode()

  /// True when hardware echo cancellation (VPIO) is running: the mic can stay
  /// open while the model speaks, which is what makes interruption possible.
  /// False on devices/OS states where VPIO fails; the caller then falls back
  /// to half-duplex muting -- worse than barge-in, but never deaf.
  private(set) var echoCancellationActive = false

  private enum AudioEngineError: Error { case zeroSampleRate }
  private var isCapturing = false
  private var wasCapturingBeforeInterruption = false
  private var useIPhoneMode = false

  private let outputFormat: AVAudioFormat

  // Accumulate resampled PCM into ~100ms chunks before sending
  private let sendQueue = DispatchQueue(label: "audio.accumulator")
  private var accumulatedData = Data()
  private let minSendBytes = 3200  // 100ms at 16kHz mono Int16 = 1600 frames * 2 bytes

  // Notification observers for background resilience
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var mediaServicesResetObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?

  init() {
    self.outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: true
    )!
  }

  func setupAudioSession(useIPhoneMode: Bool = false) throws {
    self.useIPhoneMode = useIPhoneMode
    let session = AVAudioSession.sharedInstance()
    // voiceChat: aggressive echo cancellation (mic + speaker co-located on phone)
    // videoChat: mild AEC (mic on glasses, speaker on glasses)
    // When Speaker Output is ON, speaker is on phone so always use voiceChat AEC
    let forceSpeaker = SettingsManager.shared.speakerOutputEnabled
    if useIPhoneMode || forceSpeaker {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
      )
    } else {
      try session.setCategory(
        .playAndRecord,
        mode: .videoChat,
        options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker]
      )
    }
    try session.setPreferredSampleRate(GeminiConfig.inputAudioSampleRate)
    try session.setPreferredIOBufferDuration(0.064)
    try session.setActive(true)
    if SettingsManager.shared.speakerOutputEnabled {
      try session.overrideOutputAudioPort(.speaker)
      NSLog("[Audio] Speaker output override: ON (iPhone speaker)")
    }
    NSLog("[Audio] Session mode: %@", useIPhoneMode ? "voiceChat (iPhone)" : "videoChat (glasses)")

    setupInterruptionHandling()
    setupAppLifecycleObservers()
  }

  private var vpioUnit: VoiceProcessingIOUnit?

  func startCapture() throws {
    guard !isCapturing else { return }

    // Full duplex first, via the raw VoiceProcessingIO unit -- the level
    // FaceTime-grade VoIP apps use. AVAudioEngine's wrapper mis-negotiates
    // formats on the iOS 27 beta (0 Hz input); the raw unit lets us DECLARE
    // the formats instead of reading back whatever it negotiated.
    do {
      let unit = try VoiceProcessingIOUnit()
      unit.onCapturedChunk = { [weak self] chunk in self?.handleEchoCancelledChunk(chunk) }
      try unit.start()
      vpioUnit = unit
      echoCancellationActive = true
      isCapturing = true
      NSLog("[Audio] Capture running on raw VPIO, echo cancellation: ON")
      return
    } catch {
      NSLog("[Audio] Raw VPIO unavailable, half-duplex fallback: %@", "\(error)")
    }

    try startEngine(voiceProcessing: false)
    echoCancellationActive = false
    isCapturing = true
    NSLog("[Audio] Capture running, echo cancellation: OFF (half-duplex fallback)")
  }

  private func startEngine(voiceProcessing: Bool) throws {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()

    if voiceProcessing {
      // Before any wiring or format reads: this swaps the whole IO unit.
      try engine.outputNode.setVoiceProcessingEnabled(true)
    }

    engine.attach(player)
    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: false
    )!
    engine.connect(player, to: engine.mainMixerNode, format: playerFormat)

    let inputNode = engine.inputNode
    let inputNativeFormat = inputNode.outputFormat(forBus: 0)

    NSLog("[Audio] Native input format: %@ sampleRate=%.0f channels=%d",
          inputNativeFormat.commonFormat == .pcmFormatFloat32 ? "Float32" :
          inputNativeFormat.commonFormat == .pcmFormatInt16 ? "Int16" : "Other",
          inputNativeFormat.sampleRate, inputNativeFormat.channelCount)

    // The known VPIO failure mode: a dead IO that reports 0 Hz and never
    // delivers a buffer. Throwing here retries without voice processing.
    guard inputNativeFormat.sampleRate > 0, inputNativeFormat.channelCount > 0 else {
      throw AudioEngineError.zeroSampleRate
    }

    // Always tap in native format (Float32) and convert to Int16 PCM manually.
    // AVAudioEngine taps don't reliably convert between sample formats inline.
    let needsResample = inputNativeFormat.sampleRate != GeminiConfig.inputAudioSampleRate
        || inputNativeFormat.channelCount != GeminiConfig.audioChannels

    NSLog("[Audio] Needs resample: %@", needsResample ? "YES" : "NO")

    sendQueue.async { self.accumulatedData = Data() }

    var converter: AVAudioConverter?
    if needsResample {
      let resampleFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: GeminiConfig.inputAudioSampleRate,
        channels: GeminiConfig.audioChannels,
        interleaved: false
      )!
      converter = AVAudioConverter(from: inputNativeFormat, to: resampleFormat)
    }

    var tapCount = 0
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
      guard let self else { return }

      tapCount += 1
      let pcmData: Data

      if let converter {
        let resampleFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: GeminiConfig.inputAudioSampleRate,
          channels: GeminiConfig.audioChannels,
          interleaved: false
        )!
        guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: resampleFormat) else {
          if tapCount <= 3 { NSLog("[Audio] Resample failed for tap #%d", tapCount) }
          return
        }
        pcmData = self.float32BufferToInt16Data(resampled)
      } else {
        pcmData = self.float32BufferToInt16Data(buffer)
      }

      // Accumulate into ~100ms chunks before sending to Gemini
      self.sendQueue.async {
        self.accumulatedData.append(pcmData)
        if self.accumulatedData.count >= self.minSendBytes {
          let chunk = self.accumulatedData
          self.accumulatedData = Data()
          if tapCount <= 3 {
            NSLog("[Audio] Sending chunk: %d bytes (~%dms)",
                  chunk.count, chunk.count / 32)  // 16kHz * 2 bytes = 32 bytes/ms
          }
          self.onAudioCaptured?(chunk)
        }
      }
    }

    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
    }
    player.play()

    audioEngine = engine
    playerNode = player
  }

  // MARK: - Local barge-in
  //
  // The server can only interrupt generation it is still doing, and it
  // generates a whole answer in a few seconds while the phone plays it out for
  // thirty -- so most of the time the user speaks, there is nothing server-side
  // to interrupt. Their words still land (they become the next turn); what
  // fails is only the speaker refusing to shut up. That half is client-side
  // physics: while queued audio is playing, sustained voice energy on the
  // echo-cancelled mic means a human is talking over us -- flush the queue.
  // Only runs with echo cancellation active: on the raw fallback path the
  // playback itself leaks into the mic and would self-trigger.
  private var loudChunkStreak = 0

  private func handleEchoCancelledChunk(_ chunk: Data) {
    if let vpioUnit, vpioUnit.hasQueuedPlayback {
      if Self.rmsOfInt16(chunk) > 700 {
        loudChunkStreak += 1
        // Chunks are ~100 ms; two in a row is deliberate speech, not a cough.
        if loudChunkStreak >= 2 {
          NSLog("[Audio] Local barge-in: flushing queued playback")
          vpioUnit.clearPlayback()
          loudChunkStreak = 0
        }
      } else {
        loudChunkStreak = 0
      }
    } else {
      loudChunkStreak = 0
    }
    onAudioCaptured?(chunk)
  }

  private static func rmsOfInt16(_ data: Data) -> Double {
    data.withUnsafeBytes { raw -> Double in
      let samples = raw.bindMemory(to: Int16.self)
      guard !samples.isEmpty else { return 0 }
      var sum = 0.0
      for sample in samples { sum += Double(sample) * Double(sample) }
      return (sum / Double(samples.count)).squareRoot()
    }
  }

  func playAudio(data: Data) {
    guard isCapturing, !data.isEmpty else { return }
    if let vpioUnit {
      vpioUnit.enqueuePlayback(data)
      return
    }

    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: false
    )!

    let frameCount = UInt32(data.count) / (GeminiConfig.audioBitsPerSample / 8 * GeminiConfig.audioChannels)
    guard frameCount > 0 else { return }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
    buffer.frameLength = frameCount

    guard let floatData = buffer.floatChannelData else { return }
    data.withUnsafeBytes { rawBuffer in
      guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
      for i in 0..<Int(frameCount) {
        floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
      }
    }

    playerNode.scheduleBuffer(buffer)
    if !playerNode.isPlaying {
      playerNode.play()
    }
  }

  func stopPlayback() {
    if let vpioUnit {
      vpioUnit.clearPlayback()
      return
    }
    playerNode.stop()
    playerNode.play()
  }

  func stopCapture() {
    guard isCapturing else { return }
    if let vpioUnit {
      vpioUnit.stop()
      self.vpioUnit = nil
    } else {
      audioEngine.inputNode.removeTap(onBus: 0)
      playerNode.stop()
      audioEngine.stop()
      audioEngine.detach(playerNode)
    }
    isCapturing = false
    // Flush any remaining accumulated audio
    sendQueue.async {
      if !self.accumulatedData.isEmpty {
        let chunk = self.accumulatedData
        self.accumulatedData = Data()
        self.onAudioCaptured?(chunk)
      }
    }
    removeObservers()
  }

  // MARK: - Audio Interruption & Route Change Handling

  private func setupInterruptionHandling() {
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      var shouldResume = false
      if type == .ended,
         let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        shouldResume = options.contains(.shouldResume)
      }

      self.handleInterruption(type: type, shouldResume: shouldResume)
    }

    routeChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
      else { return }

      self.handleRouteChange(reason: reason)
    }

    mediaServicesResetObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      self?.attemptAudioReset()
    }
  }

  private func setupAppLifecycleObservers() {
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      NSLog("[Audio] App will enter foreground")
      if self.isCapturing && !self.audioEngine.isRunning {
        NSLog("[Audio] Audio engine stopped while backgrounded, attempting reset")
        self.attemptAudioReset()
      }
    }
  }

  private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
    switch type {
    case .began:
      NSLog("[Audio] Audio interruption began (e.g. phone call)")
      wasCapturingBeforeInterruption = isCapturing
      if isCapturing {
        audioEngine.pause()
      }
    case .ended:
      NSLog("[Audio] Audio interruption ended (shouldResume=%@)", shouldResume ? "true" : "false")
      if wasCapturingBeforeInterruption {
        resumeAudioAfterInterruption()
      }
    @unknown default:
      break
    }
  }

  private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
    switch reason {
    case .newDeviceAvailable:
      NSLog("[Audio] New audio device available")
    case .oldDeviceUnavailable:
      NSLog("[Audio] Audio device removed")
      if isCapturing {
        attemptAudioReset()
      }
    case .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange:
      NSLog("[Audio] Audio route change: %d", reason.rawValue)
    default:
      break
    }
  }

  private func resumeAudioAfterInterruption() {
    NSLog("[Audio] Resuming audio after interruption")
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setActive(true)
      try audioEngine.start()
      NSLog("[Audio] Audio resumed successfully")
    } catch {
      NSLog("[Audio] Failed to resume audio: %@", error.localizedDescription)
      attemptAudioReset()
    }
  }

  private func attemptAudioReset() {
    NSLog("[Audio] Attempting audio reset")
    let wasCapturing = isCapturing

    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    isCapturing = false

    if wasCapturing {
      do {
        try setupAudioSession(useIPhoneMode: useIPhoneMode)
        try startCapture()
        NSLog("[Audio] Audio reset successful")
      } catch {
        NSLog("[Audio] Audio reset failed: %@", error.localizedDescription)
      }
    }
  }

  private func removeObservers() {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeChangeObserver = nil
    }
    if let observer = mediaServicesResetObserver {
      NotificationCenter.default.removeObserver(observer)
      mediaServicesResetObserver = nil
    }
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
      foregroundObserver = nil
    }
  }

  // MARK: - Private helpers

  private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let floatData = buffer.floatChannelData else { return 0 }
    var sumSquares: Float = 0
    for i in 0..<frameCount {
      let s = floatData[0][i]
      sumSquares += s * s
    }
    return sqrt(sumSquares / Float(frameCount))
  }

  private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
    var int16Array = [Int16](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
      let sample = max(-1.0, min(1.0, floatData[0][i]))
      int16Array[i] = Int16(sample * Float(Int16.max))
    }
    return int16Array.withUnsafeBufferPointer { ptr in
      Data(buffer: ptr)
    }
  }

  private func convertBuffer(
    _ inputBuffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
      return nil
    }

    var error: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if error != nil {
      return nil
    }

    return outputBuffer
  }
}


// MARK: - Raw VoiceProcessingIO

/// The system echo canceller, addressed directly. Capture and playback both
/// run in Gemini's wire formats (16 kHz / 24 kHz mono Int16) declared up
/// front, so no conversion happens anywhere and a format the unit cannot do
/// fails loudly at setup instead of silently delivering nothing.
final class VoiceProcessingIOUnit {
  enum VPIOError: Error, CustomStringConvertible {
    case componentNotFound
    case osStatus(String, OSStatus)
    var description: String {
      switch self {
      case .componentNotFound: return "VPIO component not found"
      case .osStatus(let stage, let code): return "\(stage) failed (\(code))"
      }
    }
  }

  var onCapturedChunk: ((Data) -> Void)?

  private var unit: AudioUnit!
  private let captureBuffer: UnsafeMutableRawPointer
  private let captureBufferBytes = 16384

  // Playback ring: Gemini audio in, render callback out. The render thread
  // takes the lock only for a memcpy-sized critical section.
  private let playbackLock = NSLock()
  private var playbackData = Data()

  // Capture accumulation happens on the IO thread (callbacks are serial);
  // delivery hops off it so the send path never blocks audio.
  private var pendingCapture = Data()
  private let minSendBytes = 3200  // ~100 ms at 16 kHz mono Int16
  private let deliveryQueue = DispatchQueue(label: "vpio.delivery")

  init() throws {
    captureBuffer = UnsafeMutableRawPointer.allocate(byteCount: captureBufferBytes, alignment: 16)

    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &desc) else {
      captureBuffer.deallocate()
      throw VPIOError.componentNotFound
    }
    var instance: AudioUnit?
    try Self.check("instantiate", AudioComponentInstanceNew(component, &instance))
    unit = instance

    var one: UInt32 = 1
    try Self.check("enable mic", AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
      &one, UInt32(MemoryLayout<UInt32>.size)))

    var captureFormat = Self.pcm16Mono(sampleRate: GeminiConfig.inputAudioSampleRate)
    try Self.check("capture format", AudioUnitSetProperty(
      unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
      &captureFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

    var playbackFormat = Self.pcm16Mono(sampleRate: GeminiConfig.outputAudioSampleRate)
    try Self.check("playback format", AudioUnitSetProperty(
      unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
      &playbackFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

    let ref = Unmanaged.passUnretained(self).toOpaque()
    var inputCallback = AURenderCallbackStruct(inputProc: vpioCaptureProc, inputProcRefCon: ref)
    try Self.check("capture callback", AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1,
      &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    var renderCallback = AURenderCallbackStruct(inputProc: vpioRenderProc, inputProcRefCon: ref)
    try Self.check("render callback", AudioUnitSetProperty(
      unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
      &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    try Self.check("initialize", AudioUnitInitialize(unit))
  }

  deinit {
    captureBuffer.deallocate()
  }

  func start() throws {
    try Self.check("start", AudioOutputUnitStart(unit))
  }

  func stop() {
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
  }

  func enqueuePlayback(_ data: Data) {
    playbackLock.lock()
    playbackData.append(data)
    playbackLock.unlock()
  }

  func clearPlayback() {
    playbackLock.lock()
    playbackData.removeAll(keepingCapacity: true)
    playbackLock.unlock()
  }

  var hasQueuedPlayback: Bool {
    playbackLock.lock()
    defer { playbackLock.unlock() }
    return !playbackData.isEmpty
  }

  fileprivate func renderCapture(
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32
  ) -> OSStatus {
    let byteCount = min(Int(frames) * 2, captureBufferBytes)
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(byteCount),
        mData: captureBuffer))
    let status = AudioUnitRender(unit, flags, timestamp, bus, frames, &bufferList)
    guard status == noErr else { return status }

    pendingCapture.append(Data(bytes: captureBuffer, count: Int(bufferList.mBuffers.mDataByteSize)))
    if pendingCapture.count >= minSendBytes {
      let chunk = pendingCapture
      pendingCapture = Data()
      deliveryQueue.async { [weak self] in self?.onCapturedChunk?(chunk) }
    }
    return noErr
  }

  fileprivate func renderPlayback(
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    var needed = 0
    for buffer in buffers { needed += Int(buffer.mDataByteSize) }

    playbackLock.lock()
    let available = min(needed, playbackData.count)
    let slice = playbackData.prefix(available)
    if available > 0 { playbackData.removeFirst(available) }
    playbackLock.unlock()

    var offset = 0
    for buffer in buffers {
      guard let target = buffer.mData else { continue }
      let want = Int(buffer.mDataByteSize)
      let have = max(0, min(want, available - offset))
      if have > 0 {
        slice.withUnsafeBytes { raw in
          target.copyMemory(from: raw.baseAddress!.advanced(by: offset), byteCount: have)
        }
      }
      if have < want {
        memset(target.advanced(by: have), 0, want - have)
      }
      offset += have
    }
    if available == 0 {
      flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    }
    return noErr
  }

  private static func pcm16Mono(sampleRate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0)
  }

  private static func check(_ stage: String, _ status: OSStatus) throws {
    guard status == noErr else { throw VPIOError.osStatus(stage, status) }
  }
}

private func vpioCaptureProc(
  _ refCon: UnsafeMutableRawPointer,
  _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  _ timestamp: UnsafePointer<AudioTimeStamp>,
  _ bus: UInt32,
  _ frames: UInt32,
  _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  Unmanaged<VoiceProcessingIOUnit>.fromOpaque(refCon).takeUnretainedValue()
    .renderCapture(flags, timestamp, bus, frames)
}

private func vpioRenderProc(
  _ refCon: UnsafeMutableRawPointer,
  _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  _ timestamp: UnsafePointer<AudioTimeStamp>,
  _ bus: UInt32,
  _ frames: UInt32,
  _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  guard let ioData else { return noErr }
  return Unmanaged<VoiceProcessingIOUnit>.fromOpaque(refCon).takeUnretainedValue()
    .renderPlayback(flags, frames, ioData)
}
