import SwiftUI
import AVFoundation

struct CameraPreview : View
{
    let cameraController: CameraController?
    let labels: CameraCaptureView.LocalizedLabels

    var body: some View {
        Group {
            if let previewLayer = cameraController?.previewLayer {
                AVCaptureVideoPreviewLayerViewRepresentable(previewLayer: previewLayer)
                    .scaleEffect(x: -1, y: 1)
            } else if cameraController?.captureStatus == .initializing {
                ProgressView(labels.initializingCamera)
                    .progressViewStyle(.circular)
                    .colorInvert()
                    .brightness(1)
                    .labelsHidden()
            } else {
                ContentUnavailableView(labels.cameraNotAvailable, systemImage: "video.slash")
                    .foregroundStyle(.white)
            }
        }
    }
    
    struct AVCaptureVideoPreviewLayerViewRepresentable: NSViewRepresentable
    {
        let previewLayer: AVCaptureVideoPreviewLayer
        
        func makeNSView(context: Context) -> AVCaptureVideoPreviewLayerView {
            let view = AVCaptureVideoPreviewLayerView()
            view.previewLayer = previewLayer
            return view
        }
        
        func updateNSView(_ uiView: AVCaptureVideoPreviewLayerView, context: Context) {
            previewLayer.frame = uiView.bounds
        }
        
        class AVCaptureVideoPreviewLayerView: NSView
        {
            var previewLayer: AVCaptureVideoPreviewLayer? {
                didSet {
                    oldValue?.removeFromSuperlayer()
                    self.layer = previewLayer
                }
            }
        }
    }
}

