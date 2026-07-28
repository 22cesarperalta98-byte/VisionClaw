import Foundation

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured
  /// Partial agent output while a cloud-streamed task is running (for live UI).
  @Published var streamingText: String = ""

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private let maxHistoryTurns = 10

  private static let stableSessionKey = "agent:main:glass"

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.stableSessionKey
  }

  func checkConnection() async {
    guard GeminiConfig.isAgentConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/v1/chat/completions") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, response) = try await pingSession.data(for: request)
      if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
        connectionState = .connected
        NSLog("[OpenClaw] Gateway reachable (HTTP %d)", http.statusCode)
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    // Append the new user message to conversation history
    conversationHistory.append(["role": "user", "content": task])

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    // Cloud gateway supports SSE streaming; the local gateway keeps the
    // original non-streaming path untouched.
    let useStreaming = GeminiConfig.agentBackend == .cloud

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": useStreaming
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation (streaming: %d)", conversationHistory.count, useStreaming ? 1 : 0)

    if useStreaming {
      do {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let content = try await streamCompletion(request: request)
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result (streamed): %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      } catch {
        NSLog("[OpenClaw] Streaming error: %@", error.localizedDescription)
        lastToolCallStatus = .failed(toolName, error.localizedDescription)
        return .failure("Agent error: \(error.localizedDescription)")
      }
    }

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let detail = OpenClawBridge.errorMessage(from: data) ?? "HTTP \(code)"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(detail.prefix(200)))
        lastToolCallStatus = .failed(toolName, detail)
        return .failure("Agent error: \(detail)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        // Append assistant response to history for continuity
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }

  // MARK: - SSE streaming (cloud backend)

  /// Consume an OpenAI-style SSE stream ("data: {...}" chunks terminated by
  /// "data: [DONE]"), publishing partial text to `streamingText` as it arrives.
  /// Falls back to plain JSON parsing when the server responds without SSE.
  private func streamCompletion(request: URLRequest) async throws -> String {
    streamingText = ""

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw NSError(
        domain: "OpenClawBridge", code: code,
        userInfo: [NSLocalizedDescriptionKey: "Agent returned HTTP \(code)"])
    }

    // Non-SSE response (e.g. an older gateway): collect the body and parse as JSON.
    if response.mimeType != "text/event-stream" {
      var data = Data()
      for try await byte in bytes { data.append(byte) }
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let message = choices.first?["message"] as? [String: Any],
         let content = message["content"] as? String {
        return content
      }
      return String(data: data, encoding: .utf8) ?? "OK"
    }

    var accumulated = ""
    for try await line in bytes.lines {
      guard line.hasPrefix("data: ") else { continue }
      let payload = String(line.dropFirst(6))
      if payload == "[DONE]" { break }

      guard let data = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String else { continue }

      accumulated += content
      streamingText = accumulated
    }

    streamingText = ""
    return accumulated.isEmpty ? "OK" : accumulated
  }

  // MARK: - Helpers

  /// Extract a human-readable message from a JSON error body
  /// (supports {"error": {"message": ...}} and {"error": "..."}).
  static func errorMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let err = json["error"] as? [String: Any], let message = err["message"] as? String {
      return message
    }
    if let message = json["error"] as? String {
      return message
    }
    return nil
  }

  // MARK: - Session-end context handoff (cloud backend only)

  /// When a voice session ends, hand the delegation history to the cloud agent
  /// as background context so continuity survives across sessions. Fire-and-forget.
  func flushSessionContext() {
    guard GeminiConfig.agentBackend == .cloud, GeminiConfig.isAgentConfigured else { return }
    let recent = conversationHistory.suffix(6)
    guard !recent.isEmpty else { return }

    let summary = recent
      .map { "\($0["role"] ?? "?"): \($0["content"] ?? "")" }
      .joined(separator: "\n")

    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/context") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = ["context": "Voice session ended. Recent delegated exchanges:\n\(summary)"]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let task = session.dataTask(with: request) { _, _, error in
      if let error {
        NSLog("[OpenClaw] Context flush failed: %@", error.localizedDescription)
      } else {
        NSLog("[OpenClaw] Session context flushed")
      }
    }
    task.resume()
  }
}
