/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  /// nil when the Wearables SDK could not start (no hardware, e.g. the
  /// simulator). Accessing `Wearables.shared` after a failed `configure()`
  /// traps, so nothing glasses-related may be built in that case.
  private let wearables: WearablesInterface?

  init() {
    var available: WearablesInterface?
    do {
      try Wearables.configure()
      available = Wearables.shared
    } catch {
      NSLog("[CameraAccess] Wearables SDK unavailable: \(error)")
    }
    self.wearables = available
  }

  var body: some Scene {
    WindowGroup {
      if let wearables {
        WearablesRootView(wearables: wearables)
      } else {
        // Keep the app usable for settings and cloud-agent work instead of
        // crashing, so UI can be developed without a headset.
        NoWearablesView()
      }
    }
  }
}

/// The normal app: everything that needs the glasses SDK.
private struct WearablesRootView: View {
  let wearables: WearablesInterface
  @StateObject private var viewModel: WearablesViewModel

  #if canImport(MWDATMockDevice)
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self._viewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some View {
    // Main app view with access to the shared Wearables SDK instance
    MainAppView(wearables: wearables, viewModel: viewModel)
      // Show error alerts for view model failures
      .alert("Error", isPresented: $viewModel.showError) {
        Button("OK") { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage)
      }
      #if canImport(MWDATMockDevice)
      .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
        MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      }
      #endif

    // Registration view handles the flow for connecting to the glasses via Meta AI
    RegistrationView(viewModel: viewModel)
  }
}

/// Shown when the Wearables SDK is unavailable. Everything that does not need
/// glasses -- backend selection, connected apps, task history -- still works.
private struct NoWearablesView: View {
  /// `-openSettings` presents Settings at launch, so the screen can be captured
  /// on a simulator with no GUI to tap through.
  @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-openSettings")

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("Glasses unavailable")
        .font(.headline)
      Text("The Meta Wearables SDK could not start on this device, so streaming is disabled. Settings and cloud agent features still work.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Button("Open Settings") { showSettings = true }
        .buttonStyle(.borderedProminent)
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
  }
}
