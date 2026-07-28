import Foundation
import UIKit

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3

  /// Supplied by the session wiring. Injected as closures rather than a view
  /// model reference so the router stays independent of the camera stack, and
  /// so look_closely simply goes unanswered when there is no camera.
  var captureStill: (() async -> UIImage?)?
  var sendStill: ((UIImage) -> Void)?

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    if callName == "look_closely" {
      let task = Task { @MainActor in
        guard let captureStill, let sendStill else {
          sendResponse(self.buildToolResponse(
            callId: callId, name: callName,
            result: .failure("No camera is streaming, so there is nothing to photograph.")))
          self.inFlightTasks.removeValue(forKey: callId)
          return
        }
        let image = await captureStill()
        guard !Task.isCancelled else { return }

        let result: ToolResult
        if let image {
          sendStill(image)
          // The photo goes over the realtime channel, not in this response --
          // Live function results are text-only. Tell the model to wait a beat
          // so it does not answer from the stale frame it already has.
          result = .success(
            "A sharp full-resolution photo was just sent to your view. Look at that new image and "
              + "answer from it. Ignore the earlier blurry frames.")
        } else {
          result = .failure("The photo could not be captured. Ask the user to hold still and try again.")
        }
        NSLog("[ToolCall] look_closely -> %@", image == nil ? "failed" : "sent still")
        sendResponse(self.buildToolResponse(callId: callId, name: callName, result: result))
        self.inFlightTasks.removeValue(forKey: callId)
      }
      inFlightTasks[callId] = task
      return
    }

    // On-device tools run locally: no backend, no circuit breaker, no network.
    if LocalCalendarTools.toolNames.contains(callName) {
      let task = Task { @MainActor in
        let result = await LocalCalendarTools.shared.handle(name: callName, args: call.args)
        guard !Task.isCancelled else { return }
        NSLog("[ToolCall] Local result for %@: %@", callName, String(describing: result))
        sendResponse(self.buildToolResponse(callId: callId, name: callName, result: result))
        self.inFlightTasks.removeValue(forKey: callId)
      }
      inFlightTasks[callId] = task
      return
    }

    // Circuit breaker: stop sending tool calls after repeated failures
    if consecutiveFailures >= maxConsecutiveFailures {
      NSLog("[ToolCall] Circuit breaker open (%d consecutive failures), rejecting %@",
            consecutiveFailures, callId)
      let errorResult: ToolResult = .failure(
        "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. " +
        "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
      )
      let response = buildToolResponse(callId: callId, name: callName, result: errorResult)
      sendResponse(response)
      return
    }

    let task = Task { @MainActor in
      let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
      let result = await bridge.delegateTask(task: taskDesc, toolName: callName)

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      switch result {
      case .success:
        self.consecutiveFailures = 0
      case .failure:
        self.consecutiveFailures += 1
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
    consecutiveFailures = 0
  }

  // MARK: - Private

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
