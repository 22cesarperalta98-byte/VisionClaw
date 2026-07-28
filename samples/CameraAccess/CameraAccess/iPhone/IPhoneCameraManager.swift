import AVFoundation
import UIKit

class IPhoneCameraManager: NSObject {
  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let sessionQueue = DispatchQueue(label: "iphone-camera-session")
  private let context = CIContext()
  private var isRunning = false

  /// For AVCaptureVideoPreviewLayer. Drawing the preview from the session
  /// directly is both sharper and cheaper than displaying the converted frames:
  /// the layer composites in hardware at native resolution, while a UIImage of a
  /// 480x360 buffer gets stretched about fivefold to fill the screen.
  var session: AVCaptureSession { captureSession }

  /// Only frames at least this far apart are converted. The conversion is a
  /// CPU-side CIImage -> CGImage round trip and used to run on all ~30 fps even
  /// though the model is sent one per second; the other 29 were discarded.
  var minimumFrameInterval: TimeInterval = GeminiConfig.videoFrameInterval
  private var lastConvertedFrame: Date = .distantPast

  var onFrameCaptured: ((UIImage) -> Void)?

  // MARK: - Zoom

  private var device: AVCaptureDevice?
  /// Beyond roughly this the wide-angle sensor is just upscaling, which costs
  /// detail rather than adding it -- the opposite of the point.
  private let maxZoom: CGFloat = 8

  private(set) var currentZoom: CGFloat = 1

  var maxAvailableZoom: CGFloat {
    guard let device else { return 1 }
    return min(device.activeFormat.videoMaxZoomFactor, maxZoom)
  }

  /// Optical-then-digital zoom applied at the sensor, so it sharpens what is
  /// captured rather than enlarging an already-encoded frame. Both the preview
  /// and the frames sent to the model follow it, since both come off the same
  /// session.
  func setZoom(_ factor: CGFloat) {
    guard let device else { return }
    let clamped = min(max(factor, 1), maxAvailableZoom)
    sessionQueue.async { [weak self] in
      do {
        try device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        Task { @MainActor in self?.currentZoom = clamped }
      } catch {
        NSLog("[iPhoneCamera] Zoom failed: %@", error.localizedDescription)
      }
    }
  }

  func start() {
    guard !isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.configureSession()
      self?.captureSession.startRunning()
      self?.isRunning = true
    }
  }

  func stop() {
    guard isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.captureSession.stopRunning()
      self?.isRunning = false
    }
  }

  private func configureSession() {
    captureSession.beginConfiguration()
    // 1920x1080 rather than .medium's 480x360. Affordable now that conversion is
    // throttled: the preview layer costs nothing extra, and only one frame a
    // second reaches the CPU path.
    captureSession.sessionPreset =
      captureSession.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

    // Add back camera input
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      NSLog("[iPhoneCamera] Failed to access back camera")
      captureSession.commitConfiguration()
      return
    }
    device = camera

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    // Add video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    // Force portrait-oriented frames from the sensor
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
    NSLog("[iPhoneCamera] Session configured")
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard onFrameCaptured != nil else { return }
    let now = Date()
    guard now.timeIntervalSince(lastConvertedFrame) >= minimumFrameInterval else { return }
    lastConvertedFrame = now

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let image = UIImage(cgImage: cgImage)

    onFrameCaptured?(image)
  }
}
