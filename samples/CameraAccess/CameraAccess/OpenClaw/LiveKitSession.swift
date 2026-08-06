import AVFoundation
import Foundation
import LiveKit
import SwiftUI

/// The entire voice+vision client, post-migration: join a LiveKit room, publish
/// mic and camera, subscribe to the agent's audio. Everything the direct
/// connection hand-rolled -- echo cancellation, interruption, turn-taking,
/// reconnection -- lives in WebRTC and the server-side agent now. What remains
/// on the phone is a room ticket and two track toggles.
@MainActor
final class LiveKitSession: NSObject, ObservableObject {
  enum State: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  /// What the agent is doing right now, surfaced so a dead worker is visible
  /// instead of an empty room that politely ignores you. Driven by agent
  /// presence in the room plus the standard `lk.agent.state` attribute the
  /// agents framework publishes (listening / thinking / speaking).
  enum AgentStatus: Equatable {
    case none        // no active call
    case waiting     // call is up, agent hasn't joined the room
    case starting    // agent joined, model session still initializing
    case listening
    case thinking
    case speaking
    case left        // agent was here and disconnected mid-call
  }

  @Published private(set) var state: State = .disconnected
  @Published private(set) var agentStatus: AgentStatus = .none
  @Published private(set) var localVideoTrack: LocalVideoTrack?
  /// Camera-only preview while no call is active. The camera IS this app;
  /// hanging up stops the listening, not the seeing.
  @Published private(set) var previewTrack: LocalVideoTrack?

  let room = Room()

  override init() {
    super.init()
    room.add(delegate: self)
  }

  var isActive: Bool { state == .connected || state == .connecting }

  func refreshAgentStatus() {
    guard state == .connected else {
      agentStatus = .none
      return
    }
    guard let agent = room.remoteParticipants.values.first(where: { $0.isAgent }) else {
      if agentStatus != .left { agentStatus = .waiting }
      return
    }
    switch agent.agentState {
    case .idle, .initializing: agentStatus = .starting
    case .listening: agentStatus = .listening
    case .thinking: agentStatus = .thinking
    case .speaking: agentStatus = .speaking
    }
  }

  // MARK: - Freeze (pin a frame for the model to refer to)

  /// While set, the screen shows this frame and the published video is muted:
  /// the model receives no newer frames, so the pinned one stays the most
  /// recent thing it has seen -- "this" means the frame the user pinned.
  @Published private(set) var frozenFrame: UIImage?

  private let frameGrabber = LatestFrameGrabber()
  private var grabberTrack: LocalVideoTrack?

  private func attachGrabber(to track: LocalVideoTrack?) {
    if let old = grabberTrack { old.remove(videoRenderer: frameGrabber) }
    grabberTrack = track
    if let track { track.add(videoRenderer: frameGrabber) }
  }

  func toggleFreeze() async {
    if frozenFrame != nil {
      await unfreeze()
    } else {
      await freeze()
    }
  }

  func freeze() async {
    guard frozenFrame == nil, let image = frameGrabber.latestImage() else { return }
    frozenFrame = image
    if state == .connected {
      if let pub = room.localParticipant.localVideoTracks.first {
        try? await pub.mute()
      }
    }
  }

  func unfreeze() async {
    guard frozenFrame != nil else { return }
    frozenFrame = nil
    if state == .connected {
      if let pub = room.localParticipant.localVideoTracks.first {
        try? await pub.unmute()
      }
    }
  }

  // MARK: - Zoom

  /// Optical-then-digital zoom applied at the sensor through whichever camera
  /// track is live (call or preview), so what you pinch into is what the model
  /// sees. Capped at 8x: past that the wide lens is upscaling, not resolving.
  @Published private(set) var zoomFactor: CGFloat = 1
  private var zoomAtGestureStart: CGFloat = 1

  private var activeCaptureDevice: AVCaptureDevice? {
    let track = localVideoTrack ?? previewTrack
    return (track?.capturer as? CameraCapturer)?.device
  }

  func beginZoomGesture() {
    zoomAtGestureStart = zoomFactor
  }

  func updateZoom(scale: CGFloat) {
    guard let device = activeCaptureDevice else { return }
    let ceiling = min(device.activeFormat.videoMaxZoomFactor, 8)
    let target = min(max(zoomAtGestureStart * scale, 1), ceiling)
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = target
      device.unlockForConfiguration()
      zoomFactor = target
    } catch {
      NSLog("[LiveKit] zoom failed: %@", error.localizedDescription)
    }
  }

  /// Hardware zoom resets whenever the camera changes hands (preview <-> call).
  private func resetZoom() {
    zoomFactor = 1
    zoomAtGestureStart = 1
  }

  /// Local, unpublished camera so the screen shows the world before and
  /// between calls. Handed off to the room on connect (one owner at a time).
  func startPreview() async {
    guard state == .disconnected || isFailed, previewTrack == nil else { return }
    let track = LocalVideoTrack.createCameraTrack(
      options: CameraCaptureOptions(position: .back))
    do {
      try await track.start()
      previewTrack = track
      attachGrabber(to: track)
    } catch {
      NSLog("[LiveKit] preview camera unavailable: %@", error.localizedDescription)
    }
  }

  private func stopPreview() async {
    if let track = previewTrack {
      previewTrack = nil
      try? await track.stop()
    }
  }

  func start() async {
    guard state == .disconnected || isFailed else { return }
    guard GeminiConfig.isAgentConfigured else {
      state = .failed("Gateway not configured. Check Settings.")
      return
    }
    state = .connecting
    await stopPreview()

    do {
      let ticket = try await fetchTicket()
      try await room.connect(url: ticket.url, token: ticket.token)
      try await room.localParticipant.setMicrophone(enabled: true)
      // Camera failure (simulator, permission denied) degrades to voice-only
      // rather than killing the call.
      do {
        // A video-call SDK defaults to the selfie camera; this app is a pair
        // of eyes on the world, so it opens on the back camera.
        try await room.localParticipant.setCamera(
          enabled: true,
          captureOptions: CameraCaptureOptions(position: .back))
        localVideoTrack = room.localParticipant.localVideoTracks
          .compactMap { $0.track as? LocalVideoTrack }
          .first
        attachGrabber(to: localVideoTrack)
      } catch {
        NSLog("[LiveKit] camera unavailable, voice-only: %@", error.localizedDescription)
      }
      state = .connected
      resetZoom()
      refreshAgentStatus()
    } catch {
      state = .failed(error.localizedDescription)
      agentStatus = .none
      await room.disconnect()
      // Even a failed call leaves the user with eyes.
      await startPreview()
    }
  }

  func stop() async {
    await room.disconnect()
    localVideoTrack = nil
    state = .disconnected
    agentStatus = .none
    resetZoom()
    frozenFrame = nil
    await startPreview()
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  // MARK: - Room ticket

  private struct Ticket: Decodable {
    let url: String
    let room: String
    let token: String
  }

  /// The gateway holds the LiveKit secret and mints a short-lived per-user
  /// room JWT. The engine choice (which realtime model answers) rides along
  /// and comes back inside the token as participant metadata for the worker.
  private func fetchTicket() async throws -> Ticket {
    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/livekit-token") else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "engine": SettingsManager.shared.intelligenceEngine.rawValue
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let detail = OpenClawBridge.errorMessage(from: data) ?? "gateway error"
      throw NSError(domain: "LiveKitSession", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return try JSONDecoder().decode(Ticket.self, from: data)
  }
}


// Room events arrive on SDK threads; each handler hops to the main actor and
// re-derives agent status from the room, so ordering races collapse into
// "recompute from current truth".
extension LiveKitSession: RoomDelegate {
  nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
    Task { @MainActor in self.refreshAgentStatus() }
  }

  nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
    let agentLeft = participant.isAgent
    Task { @MainActor in
      if agentLeft, self.state == .connected {
        self.agentStatus = .left
      } else {
        self.refreshAgentStatus()
      }
    }
  }

  nonisolated func room(
    _ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]
  ) {
    guard participant.isAgent else { return }
    Task { @MainActor in self.refreshAgentStatus() }
  }
}

/// Keeps the most recent video frame so a freeze can pin exactly what was on
/// screen. Conversion to UIImage happens only when a pin is taken.
final class LatestFrameGrabber: VideoRenderer {
  private let lock = NSLock()
  private var latestFrame: VideoFrame?

  var isAdaptiveStreamEnabled: Bool { false }
  var adaptiveStreamSize: CGSize { .zero }

  func set(size: CGSize) {}

  func render(frame: VideoFrame) {
    lock.lock()
    latestFrame = frame
    lock.unlock()
  }

  func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?) {
    render(frame: frame)
  }

  func latestImage() -> UIImage? {
    lock.lock()
    let frame = latestFrame
    lock.unlock()
    guard let frame, let pixelBuffer = frame.toCVPixelBuffer() else { return nil }
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    // The sensor delivers landscape buffers; renderers apply the frame's
    // rotation tag at display time. Converting raw pixels skips that step, so
    // apply it here or every portrait pin comes out sideways.
    switch frame.rotation {
    case ._90: ciImage = ciImage.oriented(.right)
    case ._180: ciImage = ciImage.oriented(.down)
    case ._270: ciImage = ciImage.oriented(.left)
    default: break
    }
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
