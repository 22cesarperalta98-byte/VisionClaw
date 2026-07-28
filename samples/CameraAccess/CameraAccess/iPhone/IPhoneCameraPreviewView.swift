import AVFoundation
import SwiftUI

/// Native preview for iPhone mode.
///
/// The frames sent to the model still go through the CPU path, but the picture
/// on screen comes straight off the capture session: AVCaptureVideoPreviewLayer
/// composites in hardware at the sensor's own resolution, so there is no
/// encode, no UIImage, and no upscaling. Displaying the converted frames
/// instead meant stretching a 480x360 buffer across a 2622-pixel-tall screen.
struct IPhoneCameraPreviewView: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewUIView {
    let view = PreviewUIView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewUIView, context: Context) {
    if view.previewLayer.session !== session {
      view.previewLayer.session = session
    }
  }

  final class PreviewUIView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}
