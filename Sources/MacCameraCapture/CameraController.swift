import SwiftUI
import AVFoundation

// inspired by https://developer.apple.com/documentation/avfoundation/capture_setup/avcam_building_a_camera_app

@Observable
public class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate
{
    public enum CaptureError : Swift.Error {
        case failedToCreateImage
    }
    
    public enum CaptureStatus {
        case cameraNotAvailable
        case initializing
        case ready
    }
    
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var continuation:CheckedContinuation<Data, Error>?
    private var cameraInput: AVCaptureDeviceInput?
    private var deviceObservationTasks: [Task<Void, Never>] = []
    
    // Discovers built-in cameras, external cameras and Continuity Cameras (an iPhone used as a webcam).
    // Note: For Continuity Camera, the hosting app must set the NSCameraUseContinuityCameraDeviceType Info.plist key to YES.
    private let cameraDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
        mediaType: .video,
        position: .unspecified
    )
    
    @MainActor
    public var previewLayer: AVCaptureVideoPreviewLayer?
    
    @MainActor
    public var captureStatus: CaptureStatus = .initializing
    
    @MainActor
    public var capturedPhoto: NSImage?
    
    @MainActor
    public private(set) var availableCameras: [AVCaptureDevice] = []
    
    @MainActor
    public private(set) var selectedCamera: AVCaptureDevice?
    
    public var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: .video)
            case .restricted:
                return false
            case .denied:
                return false
            case .authorized:
                return true
            @unknown default:
                return false
            }
        }
    }
    
    @MainActor
    public override init()
    {
        super.init()
        
        observeCameraConnections()
        
        Task {
            await configureSession()
        }
    }
    
    deinit
    {
        for task in deviceObservationTasks {
            task.cancel()
        }
        captureSession.stopRunning()
    }
    
    func configureSession() async
    {
        let cameras = cameraDiscoverySession.devices
        await MainActor.run {
            availableCameras = cameras
        }
        
        guard
            await isAuthorized,
            let camera = AVCaptureDevice.systemPreferredCamera ?? cameras.first,
            let cameraInput = try? AVCaptureDeviceInput(device: camera),
            captureSession.canAddInput(cameraInput),
            captureSession.canAddOutput(photoOutput)
        else {
            await MainActor.run {
                captureStatus = .cameraNotAvailable
            }
            return
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
        
        captureSession.beginConfiguration()
        captureSession.addInput(cameraInput)
        captureSession.addOutput(photoOutput)
        captureSession.sessionPreset = .photo
        captureSession.commitConfiguration()
        
        self.cameraInput = cameraInput
        
        captureSession.startRunning()
        
        await MainActor.run {
            self.previewLayer = previewLayer
            self.selectedCamera = camera
            self.captureStatus = .ready
        }
    }
    
    public func selectCamera(_ camera: AVCaptureDevice) async
    {
        guard
            camera.uniqueID != cameraInput?.device.uniqueID,
            let newInput = try? AVCaptureDeviceInput(device: camera)
        else { return }
        
        let previousInput = cameraInput
        
        captureSession.beginConfiguration()
        if let previousInput {
            captureSession.removeInput(previousInput)
        }
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
            cameraInput = newInput
        } else if let previousInput, captureSession.canAddInput(previousInput) {
            // The new camera was rejected by the session; restore the previous one
            captureSession.addInput(previousInput)
        }
        captureSession.commitConfiguration()
        
        let activeCamera = cameraInput?.device
        await MainActor.run {
            self.selectedCamera = activeCamera
        }
    }
    
    /// Keeps `availableCameras` up to date and switches away from a camera that gets
    /// unplugged (e.g. a Continuity Camera moving out of range).
    private func observeCameraConnections()
    {
        deviceObservationTasks = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.wasConnectedNotification) {
                    await self?.handleCameraConnectionChange(disconnectedCamera: nil)
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: AVCaptureDevice.wasDisconnectedNotification) {
                    await self?.handleCameraConnectionChange(disconnectedCamera: notification.object as? AVCaptureDevice)
                }
            }
        ]
    }
    
    private func handleCameraConnectionChange(disconnectedCamera: AVCaptureDevice?) async
    {
        // If the active camera was disconnected, remove its input from the session
        if let disconnectedCamera, let currentInput = cameraInput, disconnectedCamera.uniqueID == currentInput.device.uniqueID {
            captureSession.beginConfiguration()
            captureSession.removeInput(currentInput)
            captureSession.commitConfiguration()
            cameraInput = nil
        }
        
        let cameras = cameraDiscoverySession.devices
        let status = await MainActor.run {
            availableCameras = cameras
            return captureStatus
        }
        
        guard cameraInput == nil else { return }
        
        await MainActor.run {
            selectedCamera = nil
        }
        
        guard let replacement = AVCaptureDevice.systemPreferredCamera ?? cameras.first else {
            await MainActor.run {
                captureStatus = .cameraNotAvailable
            }
            return
        }
        
        if captureSession.outputs.contains(photoOutput) {
            // The session is already configured; just switch to the replacement camera
            await selectCamera(replacement)
            let recovered = cameraInput != nil
            await MainActor.run {
                captureStatus = recovered ? .ready : .cameraNotAvailable
            }
        } else if status == .cameraNotAvailable {
            // No camera was available at startup; a camera has appeared, so configure from scratch
            await MainActor.run {
                captureStatus = .initializing
            }
            await configureSession()
        }
    }
    
    public func capturePhoto() async throws
    {
        let data = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        
        self.continuation = nil
        
        await MainActor.run {
            self.capturedPhoto = NSImage(data: data)
        }
    }
    
    @objc public func photoOutput(_ captureOutput: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?)
    {
        guard let continuation else { return }
        
        guard let imageData = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CaptureError.failedToCreateImage)
            return
        }
        
        continuation.resume(with: .success(imageData))
    }
}
