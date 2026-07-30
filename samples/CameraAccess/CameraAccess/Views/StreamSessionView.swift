/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
// The app's front door: starts the selected capture source immediately and
// brings the voice session up with it, so opening the app means looking at the
// world with the assistant already listening. The glasses connect flow appears
// only when Glasses is the selected source and nothing is registered yet.
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var geminiVM = GeminiSessionViewModel()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @State private var showSettings = false

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, geminiVM: geminiVM)
      } else if captureSource == .glasses, let wearablesViewModel {
        if wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice {
          // Glasses connected: pre-streaming view with resolution + start
          NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
        } else {
          // Glasses selected but not paired yet: the connect flow
          HomeScreenView(viewModel: wearablesViewModel)
        }
      } else {
        // Camera is starting (or was denied). Not a mode chooser -- the only
        // affordance is fixing whatever kept the camera from coming up.
        cameraStartingView
      }
    }
    .task {
      viewModel.geminiSessionVM = geminiVM
      geminiVM.attachCamera { [weak viewModel] in
        await viewModel?.captureStillForAgent()
      }
      geminiVM.streamingMode = viewModel.streamingMode
      await autoStartIfNeeded()
    }
    .onChange(of: viewModel.streamingMode) { newMode in
      geminiVM.streamingMode = newMode
    }
    .onChange(of: captureSourceRaw) { _ in
      // Source switched in Settings: tear down and come back up on the other one.
      Task {
        if viewModel.isStreaming { await viewModel.stopSession() }
        await autoStartIfNeeded()
      }
    }
    .onChange(of: viewModel.isStreaming) { streaming in
      // Voice follows the camera, whichever source produced it.
      // Not in the simulator: initializing an audio unit at launch aborts in
      // AURemoteIO (RPC timeout against the sim's audio server, SIGABRT,
      // uncatchable). The AI button still works there for manual testing.
      #if !targetEnvironment(simulator)
      guard streaming, GeminiConfig.isConfigured, !geminiVM.isGeminiActive else { return }
      Task { await geminiVM.startSession() }
      #endif
    }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  /// iPhone capture starts unprompted -- that is the product. Glasses cannot:
  /// they may be off, unpaired, or on someone's face mid-conversation, so that
  /// path keeps its explicit start button.
  private func autoStartIfNeeded() async {
    guard captureSource == .iPhoneCamera, !viewModel.isStreaming else { return }
    await viewModel.handleStartIPhone()
  }

  private var cameraStartingView: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)
      VStack(spacing: 16) {
        ProgressView()
          .tint(.white)
        Text("Starting camera")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.7))
        Button("Open Settings") { showSettings = true }
          .font(.footnote)
          .tint(.white.opacity(0.6))
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
  }
}
