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
    
    @MainActor
    public var previewLayer: AVCaptureVideoPreviewLayer?
    
    @MainActor
    public var captureStatus: CaptureStatus = .initializing
    
    @MainActor
    public var capturedPhoto: NSImage?
    
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
        
        Task {
            await configureSession()
            captureSession.startRunning()
        }
    }
    
    deinit
    {
        captureSession.stopRunning()
    }
    
    func configureSession() async
    {
        guard
            await isAuthorized,
            let defaultCamera = AVCaptureDevice.default(for: .video),
            let captureDevice = try? AVCaptureDeviceInput(device: defaultCamera),
            captureSession.canAddInput(captureDevice),
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
        captureSession.addInput(captureDevice)
        captureSession.addOutput(photoOutput)
        captureSession.sessionPreset = .photo
        captureSession.commitConfiguration()
        
        captureSession.startRunning()
        
        
        await MainActor.run {
            self.previewLayer = previewLayer
            self.captureStatus = .ready
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
