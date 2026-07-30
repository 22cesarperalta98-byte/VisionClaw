import LiveKit
import SwiftUI

/// Phone-mode main screen under LiveKit: camera preview, a gear, a call
/// button. The overlays the direct connection accumulated -- status pills,
/// latency meters, mode tags, cut markers -- were instrumentation for problems
/// that now live (solved) inside WebRTC and the agent worker.
struct LiveKitStreamView: View {
  @ObservedObject var session: LiveKitSession
  @State private var showSettings = false

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      if let track = session.localVideoTrack ?? session.previewTrack {
        SwiftUIVideoView(track, layoutMode: .fill)
          .edgesIgnoringSafeArea(.all)
          .gesture(
            MagnificationGesture()
              .onChanged { scale in session.updateZoom(scale: scale) }
              .onEnded { _ in session.beginZoomGesture() }
          )
          .overlay(alignment: .topLeading) {
            if session.zoomFactor > 1.05 {
              Text(String(format: "%.1fx", session.zoomFactor))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 60)
                .padding(.leading, 16)
            }
          }
      }
      if case .failed(let why) = session.state {
        VStack(spacing: 12) {
          Text("Not connected").font(.headline).foregroundStyle(.white)
          Text(why)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
      } else if session.state == .connecting {
        VStack(spacing: 16) {
          ProgressView().tint(.white)
          Text("Connecting")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
        }
      }

      VStack {
        HStack {
          Spacer()
          Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 18))
              .foregroundStyle(.white.opacity(0.85))
              .padding(10)
              .background(.black.opacity(0.35), in: Circle())
          }
          .padding(.trailing, 16)
        }
        Spacer()
        LiveKitCallButton(session: session)
          .padding(.bottom, 24)
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }
}

/// Same call semantics as before: green to connect, red to hang up.
struct LiveKitCallButton: View {
  @ObservedObject var session: LiveKitSession

  var body: some View {
    Button {
      Task {
        if session.isActive {
          await session.stop()
        } else {
          await session.start()
        }
      }
    } label: {
      ZStack {
        Circle()
          .fill(session.isActive ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
          .frame(width: 64, height: 64)
        if session.state == .connecting {
          ProgressView().tint(.white)
        } else {
          Image(systemName: session.isActive ? "phone.down.fill" : "phone.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
    }
    .disabled(session.state == .connecting)
  }
}
