import SwiftUI

@MainActor
public struct CameraCaptureView: View
{
    enum Status : Equatable {
        case livePreview
        case capturedPhoto(image: NSImage)
    }
    
    @Environment(\.dismiss) private var dismiss

    @State private var cameraController = CameraController()
    @State private var captureErrorMessage: String = ""
    @State private var isShowingCaptureError = false
    @State private var status = Status.livePreview
    
    public let onPhotoCaptured: (NSImage) -> Void
    public let labels: LocalizedLabels

    public init(onPhotoCaptured: @escaping (NSImage) -> Void, labels: LocalizedLabels = .init(save: "Save", cancel: "Cancel", initializingCamera: "Initializing camera...", cameraNotAvailable: "Camera not available"))
    {
        self.onPhotoCaptured = onPhotoCaptured
        self.labels = labels
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch status {
                case .livePreview:
                    CameraPreview(cameraController: cameraController, labels: labels)
                case .capturedPhoto(let capturedPhoto):
                    PhotoPreview(image: capturedPhoto)
                }
            }
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .onChange(of: cameraController.capturedPhoto) { _, newPhoto in
                guard let newPhoto else { return }
                self.status = .capturedPhoto(image: newPhoto)
            }
            Controls(status: $status, cameraController: cameraController, onPhotoCaptured: onPhotoCaptured, labels: labels)
                .disabled(cameraController.captureStatus != .ready)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
    
    public struct LocalizedLabels
    {
        public init(save: String, cancel: String, initializingCamera: String, cameraNotAvailable: String)
        {
            self.save = save
            self.cancel = cancel
            self.initializingCamera = initializingCamera
            self.cameraNotAvailable = cameraNotAvailable
        }
        
        let save: String
        let cancel: String
        let initializingCamera: String
        let cameraNotAvailable: String
    }

    struct Controls : View
    {
        @Environment(\.dismiss) private var dismiss

        @State private var captureErrorMessage: String = ""
        @State private var isShowingCaptureError = false

        @Binding var status: Status

        let cameraController: CameraController
        let onPhotoCaptured: (NSImage) -> Void
        let labels: LocalizedLabels

        @ViewBuilder
        var captureButton: some View {
            Button {
                Task {
                    do {
                        try await cameraController.capturePhoto()
                    } catch {
                        captureErrorMessage = error.localizedDescription
                        isShowingCaptureError = true
                    }
                }
            } label: {
                Image(systemName: "record.circle")
                    .resizable()
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .alert("Capture failed", isPresented: $isShowingCaptureError) {
                Button("OK", role: .cancel, action: {})
            } message: {
                Text(captureErrorMessage)
            }
        }

        @ViewBuilder
        var discardPreviewButton: some View {
            Button {
                status = .livePreview
            } label: {
                Image(systemName: "x.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundColor(.gray)
        }

        var body: some View {
            HStack {
                Group {
                    Button(labels.cancel) {
                        dismiss()
                    }
                }
                .frame(width: 100)
                Spacer()
                switch status {
                case .livePreview:
                    captureButton
                default:
                    discardPreviewButton
                }
                Spacer()
                Group {
                    Button(labels.save) {
                        switch status {
                        case .capturedPhoto(let image):
                            onPhotoCaptured(image)
                        default:
                            break
                        }
                        dismiss()
                    }
                    .disabled(status == .livePreview)
                }
                .frame(width: 100)
            }
            .padding()
        }
    }
}


#Preview {
    CameraCaptureView { image in
        print("Captured image with size ", image.size)
    }
}
