import EventKit
import Foundation

/// On-device calendar and reminders via EventKit.
///
/// These run entirely on the phone: one system permission prompt, no OAuth, no
/// server credentials. Because iOS syncs Google/iCloud/Exchange calendars into
/// EventKit, "add to my calendar" reaches the user's real calendar without any
/// third-party connection. Server-side Google access is still needed for
/// background work (scheduled briefs while the phone is asleep).
@MainActor
final class LocalCalendarTools {
  static let shared = LocalCalendarTools()

  private let store = EKEventStore()
  private lazy var isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private init() {}

  // MARK: - Access

  private func ensureEventAccess() async -> Bool {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      return true
    case .notDetermined:
      return (try? await store.requestFullAccessToEvents()) ?? false
    default:
      return false
    }
  }

  private func ensureReminderAccess() async -> Bool {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess:
      return true
    case .notDetermined:
      return (try? await store.requestFullAccessToReminders()) ?? false
    default:
      return false
    }
  }

  // MARK: - Tools

  /// Read events in a window. `daysAhead` counts from now (1 = through tomorrow).
  func listEvents(daysAhead: Int) async -> ToolResult {
    guard await ensureEventAccess() else {
      return .failure("Calendar access is off. Ask the user to enable it in Settings > Privacy > Calendars.")
    }

    let start = Date()
    guard let end = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: start) else {
      return .failure("Could not compute the date range.")
    }

    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

    guard !events.isEmpty else {
      return .success("No events in the next \(daysAhead) day(s).")
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "EEE MMM d, h:mm a"
    let lines = events.prefix(25).map { event -> String in
      let when = event.isAllDay
        ? DateFormatter.localizedString(from: event.startDate, dateStyle: .medium, timeStyle: .none) + " (all day)"
        : formatter.string(from: event.startDate)
      let place = event.location.map { " at \($0)" } ?? ""
      return "\(when): \(event.title ?? "Untitled")\(place)"
    }
    return .success(lines.joined(separator: "\n"))
  }

  /// Create an event. `startISO`/`endISO` are ISO 8601; end defaults to +1h.
  func createEvent(title: String, startISO: String, endISO: String?, location: String?) async -> ToolResult {
    guard await ensureEventAccess() else {
      return .failure("Calendar access is off. Ask the user to enable it in Settings > Privacy > Calendars.")
    }
    guard let start = isoFormatter.date(from: startISO) else {
      return .failure("Could not parse the start time '\(startISO)'. Use ISO 8601, e.g. 2026-07-30T19:00:00Z.")
    }
    guard let calendar = store.defaultCalendarForNewEvents else {
      return .failure("No default calendar is available on this device.")
    }

    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = start
    event.endDate = endISO.flatMap { isoFormatter.date(from: $0) } ?? start.addingTimeInterval(3600)
    event.location = location
    event.calendar = calendar

    do {
      try store.save(event, span: .thisEvent)
      let formatter = DateFormatter()
      formatter.dateFormat = "EEE MMM d 'at' h:mm a"
      return .success("Created '\(title)' on \(formatter.string(from: start)).")
    } catch {
      return .failure("Could not save the event: \(error.localizedDescription)")
    }
  }

  /// Create a reminder, optionally due at an ISO 8601 time.
  func createReminder(title: String, dueISO: String?) async -> ToolResult {
    guard await ensureReminderAccess() else {
      return .failure("Reminders access is off. Ask the user to enable it in Settings > Privacy > Reminders.")
    }
    guard let list = store.defaultCalendarForNewReminders() else {
      return .failure("No default reminders list is available on this device.")
    }

    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = list
    if let dueISO, let due = isoFormatter.date(from: dueISO) {
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: due)
      reminder.addAlarm(EKAlarm(absoluteDate: due))
    }

    do {
      try store.save(reminder, commit: true)
      return .success("Reminder set: \(title)")
    } catch {
      return .failure("Could not save the reminder: \(error.localizedDescription)")
    }
  }

  // MARK: - Dispatch

  static let toolNames: Set<String> = ["list_calendar_events", "create_calendar_event", "create_reminder"]

  func handle(name: String, args: [String: Any]) async -> ToolResult {
    switch name {
    case "list_calendar_events":
      return await listEvents(daysAhead: args["days_ahead"] as? Int ?? 1)
    case "create_calendar_event":
      guard let title = args["title"] as? String, let start = args["start"] as? String else {
        return .failure("create_calendar_event needs a title and a start time.")
      }
      return await createEvent(
        title: title, startISO: start, endISO: args["end"] as? String,
        location: args["location"] as? String)
    case "create_reminder":
      guard let title = args["title"] as? String else {
        return .failure("create_reminder needs a title.")
      }
      return await createReminder(title: title, dueISO: args["due"] as? String)
    default:
      return .failure("Unknown local tool: \(name)")
    }
  }
}
