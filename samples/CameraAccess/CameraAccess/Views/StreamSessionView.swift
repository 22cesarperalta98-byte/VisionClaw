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
// The app's front door. Phone mode joins a LiveKit room on sight -- camera,
// mic and the assistant all come up together; everything intelligent lives
// server-side. Glasses mode keeps the DAT streaming flow (assistant voice for
// glasses returns when their frames publish into the room as a track).
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var liveKit = LiveKitSession()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue

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
      if captureSource == .iPhoneCamera {
        LiveKitStreamView(session: liveKit)
      } else if viewModel.isStreaming {
        StreamView(viewModel: viewModel)
      } else if let wearablesViewModel {
        if wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice {
          NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
        } else {
          HomeScreenView(viewModel: wearablesViewModel)
        }
      } else {
        Color.black.edgesIgnoringSafeArea(.all)
      }
    }
    .task {
      if captureSource == .iPhoneCamera {
        await liveKit.start()
      }
    }
    .onChange(of: captureSourceRaw) { newRaw in
      Task {
        if CaptureSource(rawValue: newRaw) == .iPhoneCamera {
          if viewModel.isStreaming { await viewModel.stopSession() }
          await liveKit.start()
        } else {
          await liveKit.stop()
        }
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
