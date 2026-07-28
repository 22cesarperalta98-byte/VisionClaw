import Foundation

// MARK: - Gemini Tool Call (parsed from server JSON)

struct GeminiFunctionCall {
  let id: String
  let name: String
  let args: [String: Any]
}

struct GeminiToolCall {
  let functionCalls: [GeminiFunctionCall]

  init?(json: [String: Any]) {
    guard let toolCall = json["toolCall"] as? [String: Any],
          let calls = toolCall["functionCalls"] as? [[String: Any]] else {
      return nil
    }
    self.functionCalls = calls.compactMap { call in
      guard let id = call["id"] as? String,
            let name = call["name"] as? String else { return nil }
      let args = call["args"] as? [String: Any] ?? [:]
      return GeminiFunctionCall(id: id, name: name, args: args)
    }
  }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
  let ids: [String]

  init?(json: [String: Any]) {
    guard let cancellation = json["toolCallCancellation"] as? [String: Any],
          let ids = cancellation["ids"] as? [String] else {
      return nil
    }
    self.ids = ids
  }
}

// MARK: - Tool Result

enum ToolResult {
  case success(String)
  case failure(String)

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": result]
    case .failure(let error):
      return ["error": error]
    }
  }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
  case idle
  case executing(String)
  case completed(String)
  case failed(String, String)
  case cancelled(String)

  var displayText: String {
    switch self {
    case .idle: return ""
    case .executing(let name): return "Running: \(name)..."
    case .completed(let name): return "Done: \(name)"
    case .failed(let name, let err): return "Failed: \(name) - \(err)"
    case .cancelled(let name): return "Cancelled: \(name)"
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - Tool Declarations (for Gemini setup message)

enum ToolDeclarations {

  static func allDeclarations() -> [[String: Any]] {
    return [execute, listCalendarEvents, createCalendarEvent, createReminder]
  }

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  // MARK: - On-device tools (EventKit)
  // These run on the phone with no server round-trip, so they answer instantly
  // and work even with no agent backend configured.

  static let listCalendarEvents: [String: Any] = [
    "name": "list_calendar_events",
    "description": "Read the user's own calendar on this phone. Use for 'what's on my calendar', 'am I free', 'what's my day look like'. Instant, no network.",
    "parameters": [
      "type": "object",
      "properties": [
        "days_ahead": [
          "type": "integer",
          "description": "How many days ahead to look. 1 = today and tomorrow. Defaults to 1."
        ]
      ],
      "required": [] as [String]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let createCalendarEvent: [String: Any] = [
    "name": "create_calendar_event",
    "description": "Add an event to the user's calendar on this phone. Use for 'put X on my calendar', 'schedule Y'. Resolve relative dates ('tomorrow at 7') into an absolute time before calling. Instant, no network.",
    "parameters": [
      "type": "object",
      "properties": [
        "title": ["type": "string", "description": "Event title."],
        "start": [
          "type": "string",
          "description": "Start time in ISO 8601 with offset, e.g. 2026-07-30T19:00:00-07:00."
        ],
        "end": ["type": "string", "description": "Optional end time in ISO 8601. Defaults to one hour after start."],
        "location": ["type": "string", "description": "Optional location."]
      ],
      "required": ["title", "start"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let createReminder: [String: Any] = [
    "name": "create_reminder",
    "description": "Add a reminder to the user's Reminders app on this phone. Use for 'remind me to X'. Instant, no network.",
    "parameters": [
      "type": "object",
      "properties": [
        "title": ["type": "string", "description": "What to be reminded about."],
        "due": ["type": "string", "description": "Optional due time in ISO 8601 with offset."]
      ],
      "required": ["title"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
}
