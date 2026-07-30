/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling. Extended with Gemini Live AI assistant integration.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @State private var showSettings = false

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Settings access. In phone mode this view is the entire app, so
      // without a gear here Settings is unreachable.
      VStack {
        HStack {
          // Measured voice-to-voice latency: last utterance end to first reply
          // audio. On screen because latency tuning is happening in the field,
          // far from Xcode.
          if geminiVM.localBargeInFlash {
            Text("CUT")
              .font(.system(.footnote, design: .monospaced).weight(.bold))
              .foregroundStyle(.orange)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.black.opacity(0.35), in: Capsule())
              .padding(.leading, 16)
          }
          if let ms = geminiVM.lastVoiceToVoiceMs {
            Text(String(format: "%.1fs", Double(ms) / 1000))
              .font(.system(.footnote, design: .monospaced).weight(.semibold))
              .foregroundStyle(.white.opacity(0.7))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.black.opacity(0.35), in: Capsule())
              .padding(.leading, 16)
          }
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
      }
      .zIndex(2)
      .sheet(isPresented: $showSettings) { SettingsView() }

      // Video backdrop
      if viewModel.streamingMode == .iPhone, let session = viewModel.iPhoneCaptureSession {
        // Straight off the capture session: hardware-composited at sensor
        // resolution, rather than a converted frame stretched to fit.
        IPhoneCameraPreviewView(session: session)
          .edgesIgnoringSafeArea(.all)
          .gesture(
            MagnificationGesture()
              .onChanged { scale in viewModel.updateIPhoneZoom(scale: scale) }
              .onEnded { _ in viewModel.beginIPhoneZoomGesture() }
          )
          .onAppear { viewModel.beginIPhoneZoomGesture() }
          .overlay(alignment: .topTrailing) {
            // Only while zoomed: at 1x the label is noise on top of the scene.
            if viewModel.iPhoneZoom > 1.05 {
              Text(String(format: "%.1fx", viewModel.iPhoneZoom))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 60)
                .padding(.trailing, 16)
            }
          }
      } else if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Transcripts + speaking indicator
      if geminiVM.isGeminiActive {
        VStack {
          Spacer()

          VStack(spacing: 8) {
            if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
              TranscriptView(
                userText: geminiVM.userTranscript,
                aiText: geminiVM.aiTranscript
              )
            }

            ToolCallStatusView(status: geminiVM.toolCallStatus)

            if geminiVM.isModelSpeaking {
              HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                  .foregroundColor(.white)
                  .font(.system(size: 14))
                SpeakingIndicator()
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(Color.black.opacity(0.5))
              .cornerRadius(20)
            }
          }
          .padding(.bottom, 80)
        }
        .padding(.all, 24)
      }

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, geminiVM: geminiVM)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
        if geminiVM.isGeminiActive {
          geminiVM.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
    // Gemini error alert
    .alert("AI Assistant", isPresented: Binding(
      get: { geminiVM.errorMessage != nil },
      set: { if !$0 { geminiVM.errorMessage = nil } }
    )) {
      Button("OK") { geminiVM.errorMessage = nil }
    } message: {
      Text(geminiVM.errorMessage ?? "")
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      // Glasses have a stop: they are a remote camera someone may be wearing.
      // The phone camera IS the app -- stopping it just strands the screen on
      // a spinner -- so phone mode has no stop; the AI button is the toggle
      // that means something, and closing the app releases the camera.
      if viewModel.streamingMode == .glasses {
        CustomButton(
          title: "Stop streaming",
          style: .destructive,
          isDisabled: false
        ) {
          Task {
            await viewModel.stopSession()
          }
        }
      }

      // Photo button (glasses mode only -- DAT SDK capture)
      if viewModel.streamingMode == .glasses {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
      }

      // One control, call semantics: connected or not. Which services sit
      // behind the call is plumbing the user should never have to read.
      CallButton(geminiVM: geminiVM)
    }
  }
}


/// The assistant as a call: green to connect, red to hang up, spinner while
/// dialing. Modeled on how consumer voice apps present it -- one icon carries
/// the whole connection story, and the per-service detail stays in Settings.
struct CallButton: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  private var isConnecting: Bool {
    if case .connecting = geminiVM.connectionState { return true }
    if case .settingUp = geminiVM.connectionState { return true }
    return false
  }

  var body: some View {
    Button {
      Task {
        if geminiVM.isGeminiActive {
          geminiVM.stopSession()
        } else {
          await geminiVM.startSession()
        }
      }
    } label: {
      ZStack {
        Circle()
          .fill(geminiVM.isGeminiActive ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
          .frame(width: 64, height: 64)
        if isConnecting {
          ProgressView().tint(.white)
        } else {
          Image(systemName: geminiVM.isGeminiActive ? "phone.down.fill" : "phone.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
    }
    .disabled(isConnecting)
  }
}
