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
    
    /// Whether the live preview is flipped horizontally, as people expect from a mirror
    /// when sitting in front of a camera. Captured photos are never mirrored.
    /// Defaults to true for the built-in camera and false for all other cameras.
    @MainActor
    public var isMirrored: Bool = false {
        didSet {
            applyMirroring()
        }
    }
    
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
        
        configurePhotoOutput(for: camera)
        
        captureSession.startRunning()
        
        await MainActor.run {
            self.previewLayer = previewLayer
            self.selectedCamera = camera
            self.captureStatus = .ready
            self.applyDefaultMirroring(for: camera)
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
        if let activeCamera {
            configurePhotoOutput(for: activeCamera)
        }
        
        await MainActor.run {
            self.selectedCamera = activeCamera
            if let activeCamera {
                self.applyDefaultMirroring(for: activeCamera)
            }
        }
    }
    
    /// Allows capturing at the camera sensor's maximum resolution (particularly relevant for Continuity Camera).
    private func configurePhotoOutput(for camera: AVCaptureDevice)
    {
        let supportedDimensions = camera.activeFormat.supportedMaxPhotoDimensions
        if let maxDimensions = supportedDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }),
           maxDimensions.width != photoOutput.maxPhotoDimensions.width || maxDimensions.height != photoOutput.maxPhotoDimensions.height {
            photoOutput.maxPhotoDimensions = maxDimensions
        }
        
        // Captured photos are never mirrored, regardless of the preview's mirroring
        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
    
    @MainActor
    private func applyDefaultMirroring(for camera: AVCaptureDevice)
    {
        // Only the built-in camera's preview shows a mirror image by default
        isMirrored = camera.deviceType == .builtInWideAngleCamera
    }
    
    /// Applies the current mirroring setting to the live preview.
    @MainActor
    private func applyMirroring()
    {
        guard let connection = previewLayer?.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isMirrored
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
        // The active format may have changed since configuration (e.g. a Continuity Camera
        // switching between landscape and portrait), so refresh the maximum photo resolution
        if let camera = cameraInput?.device {
            configurePhotoOutput(for: camera)
        }
        
        let data = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
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
