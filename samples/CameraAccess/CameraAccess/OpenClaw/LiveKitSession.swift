import Foundation
import LiveKit
import SwiftUI

/// The entire voice+vision client, post-migration: join a LiveKit room, publish
/// mic and camera, subscribe to the agent's audio. Everything the direct
/// connection hand-rolled -- echo cancellation, interruption, turn-taking,
/// reconnection -- lives in WebRTC and the server-side agent now. What remains
/// on the phone is a room ticket and two track toggles.
@MainActor
final class LiveKitSession: ObservableObject {
  enum State: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  @Published private(set) var state: State = .disconnected
  @Published private(set) var localVideoTrack: LocalVideoTrack?

  let room = Room()

  var isActive: Bool { state == .connected || state == .connecting }

  func start() async {
    guard state == .disconnected || isFailed else { return }
    guard GeminiConfig.isAgentConfigured else {
      state = .failed("Gateway not configured. Check Settings.")
      return
    }
    state = .connecting

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
      } catch {
        NSLog("[LiveKit] camera unavailable, voice-only: %@", error.localizedDescription)
      }
      state = .connected
    } catch {
      state = .failed(error.localizedDescription)
      await room.disconnect()
    }
  }

  func stop() async {
    await room.disconnect()
    localVideoTrack = nil
    state = .disconnected
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
