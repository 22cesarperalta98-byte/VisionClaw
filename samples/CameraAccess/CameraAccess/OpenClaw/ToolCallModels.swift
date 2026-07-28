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

  /// Google Calendar is the source of truth, so calendar reads and writes go
  /// through `execute` to the agent rather than to EventKit -- a scheduled run
  /// has no phone in the loop, and splitting reads from writes across two
  /// calendars means an event you create is invisible to the next question.
  /// `listCalendarEvents` / `createCalendarEvent` stay defined for the
  /// on-device path; add them back here to switch EventKit back on.
  static func allDeclarations() -> [[String: Any]] {
    return [execute, lookCloselyDeclaration, createReminder]
  }

  /// The ambient stream is one downscaled, compressed frame per second -- enough
  /// to know a receipt is being held up, not enough to read its line items. This
  /// asks for a full-resolution still instead. The image arrives as a new frame
  /// rather than as this tool's return value, because Live function responses
  /// carry text only.
  static let lookCloselyDeclaration: [String: Any] = [
    "name": "look_closely",
    "description": "Capture a sharp, full-resolution photo of what the user is looking at right now. "
      + "Use this whenever the answer depends on fine visual detail the live view is too coarse for: "
      + "reading text, receipts, labels, screens, handwriting, serial numbers, small print, or "
      + "distinguishing similar objects. Also use it when you can tell something is there but cannot "
      + "read it. After it returns, a high-resolution image arrives in your view -- answer from that, "
      + "not from the blurry live frames.",
    "parameters": [
      "type": "object",
      "properties": [
        "looking_for": [
          "type": "string",
          "description": "What detail you are trying to read or identify, e.g. 'the total on the receipt'."
        ]
      ],
      "required": [] as [String]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Your only way to take action or to look anything up. You have no memory, storage, calendar, or ability to do anything on your own -- use this tool for everything: reading and changing the user's Google Calendar (what's on it, am I free, schedule this, move that), sending messages, searching the web, adding to lists, creating notes, research, drafts, smart home control, app interactions, or any request needing current information. Answering a calendar question still requires this tool -- you cannot see the calendar yourself. When in doubt, use this tool.",
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
