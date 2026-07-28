import SwiftUI

/// Reachability of the hosted gateway, resolved by an actual authenticated
/// request. "Configured" and "working" are different things -- a wrong token
/// looks identical to a correct one until something calls the server.
enum GatewayStatus: Equatable {
  case checking
  case ready
  case notConfigured
  case unauthorized
  case unreachable(String)
}

private struct GatewayStatusLabel: View {
  let status: GatewayStatus

  var body: some View {
    switch status {
    case .checking:
      ProgressView()
    case .ready:
      Label("Connected", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .labelStyle(.titleAndIcon)
    case .notConfigured:
      Text("Not set up")
        .foregroundStyle(.secondary)
    case .unauthorized:
      Label("Token rejected", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    case .unreachable(let why):
      Label(why, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    }
  }
}

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var selectedBackend: AgentBackend = .selfHosted
  @State private var cloudGatewayURL: String = ""
  @State private var cloudGatewayToken: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showResetConfirmation = false
  @State private var gatewayStatus: GatewayStatus = .checking

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Action Agent"), footer: Text(selectedBackend == .cloud
          ? "Runs in the cloud. Nothing to install, and it keeps working when your computer is asleep."
          : "Runs on your own machine. Requires OpenClaw installed and running, and stops when that machine sleeps.")) {
          Picker("Backend", selection: $selectedBackend) {
            ForEach(AgentBackend.allCases, id: \.self) { backend in
              Text(backend.rawValue).tag(backend)
            }
          }
          .pickerStyle(.segmented)
        }

        if selectedBackend == .cloud {
          Section {
            HStack {
              Text("Status")
              Spacer()
              GatewayStatusLabel(status: gatewayStatus)
            }

            NavigationLink("Connected Apps") {
              ConnectedAppsView()
            }

            NavigationLink("Recent Tasks") {
              RecentTasksView()
            }
          }

          // The URL and token ship with working defaults, so most people never
          // need to see them; surfacing them as primary fields made a configured
          // setup look like one awaiting setup.
          Section {
            DisclosureGroup("Gateway settings") {
              VStack(alignment: .leading, spacing: 4) {
                Text("Gateway URL")
                  .font(.caption)
                  .foregroundColor(.secondary)
                TextField("https://gateway.example.com", text: $cloudGatewayURL)
                  .autocapitalization(.none)
                  .disableAutocorrection(true)
                  .keyboardType(.URL)
                  .font(.system(.body, design: .monospaced))
              }

              VStack(alignment: .leading, spacing: 4) {
                Text("Access Token")
                  .font(.caption)
                  .foregroundColor(.secondary)
                TextField("Your gateway access token", text: $cloudGatewayToken)
                  .autocapitalization(.none)
                  .disableAutocorrection(true)
                  .font(.system(.body, design: .monospaced))
              }
            }
          }
        }

        if selectedBackend == .selfHosted {
        Section(header: Text("OpenClaw"), footer: Text("Connect to an OpenClaw gateway running on your Mac for agentic tool-calling.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Host")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://your-mac.local", text: $openClawHost)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Port")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("18789", text: $openClawPort)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Hook Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Hook token", text: $openClawHookToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Gateway Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Gateway auth token", text: $openClawGatewayToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }
        }

        Section(header: Text("WebRTC")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Signaling URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("wss://your-server.example.com", text: $webrtcSignalingURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Audio"), footer: Text("Route audio output to the iPhone speaker instead of glasses. Useful for demos where others need to hear.")) {
          Toggle("Speaker Output", isOn: $speakerOutputEnabled)
        }

        Section(header: Text("Video"), footer: Text("Disable video streaming to save battery. Audio remains active for voice-only interaction.")) {
          Toggle("Video Streaming", isOn: $videoStreamingEnabled)
        }

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from OpenClaw (heartbeat, scheduled tasks) spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }


        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Enter Gemini API key", text: $geminiAPIKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }


        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            save()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        loadCurrentValues()
      }
      .task(id: selectedBackend) {
        await refreshGatewayStatus()
      }
    }
  }

  /// Ask the gateway for something that needs a valid token. /apps is the
  /// cheapest such route, and distinguishing 401 from a transport failure is
  /// the whole point -- they need opposite fixes.
  private func refreshGatewayStatus() async {
    guard selectedBackend == .cloud else { return }
    gatewayStatus = .checking
    guard GeminiConfig.isAgentConfigured,
          let url = URL(string: "\(GeminiConfig.agentBaseURL)/apps") else {
      gatewayStatus = .notConfigured
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch code {
      case 200: gatewayStatus = .ready
      case 401, 403: gatewayStatus = .unauthorized
      default: gatewayStatus = .unreachable("Server error \(code)")
      }
    } catch {
      gatewayStatus = .unreachable("Unreachable")
    }
  }

  private func loadCurrentValues() {
    geminiAPIKey = settings.geminiAPIKey
    geminiSystemPrompt = settings.geminiSystemPrompt
    selectedBackend = settings.agentBackend
    cloudGatewayURL = settings.cloudGatewayURL
    cloudGatewayToken = settings.cloudGatewayToken
    openClawHost = settings.openClawHost
    openClawPort = String(settings.openClawPort)
    openClawHookToken = settings.openClawHookToken
    openClawGatewayToken = settings.openClawGatewayToken
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
  }

  private func save() {
    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.agentBackend = selectedBackend
    settings.cloudGatewayURL = cloudGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.cloudGatewayToken = cloudGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHost = openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(openClawPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
      settings.openClawPort = port
    }
    settings.openClawHookToken = openClawHookToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawGatewayToken = openClawGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
  }
}
