//
//  MediaRecorder.swift
//  Anonycord
//
//  Created by Constantin Clerc on 7/8/24.
//

import AVFoundation
import Photos
import UIKit

class MediaRecorder: ObservableObject {
    private let captureSessionQueue = DispatchQueue(label: "ch.cclerc.Anonycord.capture-session")
    private var recordingSession: AVAudioSession!
    private var audioRecorder: AVAudioRecorder!
    private var videoOutput: AVCaptureMovieFileOutput!
    private var captureSession: AVCaptureSession!
    private var photoOutput: AVCapturePhotoOutput!

    private let videoRecordingDelegate = VideoRecordingDelegate()
    private let photoCaptureDelegate = PhotoCaptureDelegate()

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        let permissionGroup = DispatchGroup()
        var videoPermissionGranted = false

        permissionGroup.enter()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            videoPermissionGranted = granted
            permissionGroup.leave()
        }

        permissionGroup.enter()
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { _ in
                permissionGroup.leave()
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                permissionGroup.leave()
            }
        }
        PHPhotoLibrary.requestAuthorization { _ in }

        permissionGroup.notify(queue: .main) {
            completion(videoPermissionGranted)
        }
    }

    func setupCaptureSession() {
        captureSessionQueue.async {
            self.captureSession = AVCaptureSession()
            self.setupVideoInput()
            self.setupAudioInput()
            self.setupOutputs()
            self.captureSession.startRunning()
        }
    }

    private func setupVideoInput() {
        guard let captureSession = self.captureSession else {
            print("Capture session is not initialized.")
            return
        }

        for input in captureSession.inputs {
            if let videoInput = input as? AVCaptureDeviceInput {
                captureSession.removeInput(videoInput)
            }
        }

        let cameraPosition: AVCaptureDevice.Position
        let cameraType: AVCaptureDevice.DeviceType

        switch AppSettings().cameraType {
        case "Selfie":
            cameraPosition = .front
            cameraType = .builtInWideAngleCamera
        case "UltraWide":
            cameraPosition = .back
            cameraType = .builtInUltraWideCamera
        default:
            cameraPosition = .back
            cameraType = .builtInWideAngleCamera
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: cameraPosition
        ).devices

        guard let cameraDevice = devices.first(where: { $0.deviceType == cameraType }) else {
            print("No available camera found.")
            return
        }
        do {
            let configuredFormat = configureVideoFormat(on: cameraDevice)
            let videoInput = try AVCaptureDeviceInput(device: cameraDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
                if configuredFormat && captureSession.canSetSessionPreset(.inputPriority) {
                    captureSession.sessionPreset = .inputPriority
                } else {
                    setSessionPreset()
                }
            } else {
                print("Unable to add video input (?)")
            }
        } catch {
            print("error creating video input \(error)")
        }
    }

    private func configureVideoFormat(on device: AVCaptureDevice) -> Bool {
        let settings = AppSettings()
        let targetWidth: Int32 = settings.videoQuality == "4K" ? 3840 : 1920
        let targetHeight: Int32 = settings.videoQuality == "4K" ? 2160 : 1080
        let requestedFrameRate = Double(settings.videoFrameRate)

        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == targetWidth &&
                dimensions.height == targetHeight &&
                format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= requestedFrameRate && $0.maxFrameRate >= requestedFrameRate
                }
        }

        guard let format = formats.first else {
            print("\(settings.videoQuality) at \(settings.videoFrameRate) fps is not supported by this camera.")
            return false
        }

        do {
            try device.lockForConfiguration()
        } catch {
            print("Unable to configure video format: \(error.localizedDescription)")
            return false
        }
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.videoFrameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return true
    }

    private func setSessionPreset() {
        switch AppSettings().videoQuality {
        case "4K" where captureSession.canSetSessionPreset(.hd4K3840x2160):
            captureSession.sessionPreset = .hd4K3840x2160
        case "1080p" where captureSession.canSetSessionPreset(.hd1920x1080):
            captureSession.sessionPreset = .hd1920x1080
        default:
            captureSession.sessionPreset = .high
        }
    }

    private func setupAudioInput() {
        guard let audioCaptureDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioCaptureDevice),
              captureSession.canAddInput(audioInput) else { return }
        captureSession.addInput(audioInput)
    }

    private func setupOutputs() {
        videoOutput = AVCaptureMovieFileOutput()
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        photoOutput = AVCapturePhotoOutput()
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }
    }

    func startVideoRecording(completion: @escaping (URL?) -> Void) {
        deleteOldVideos()
        videoRecordingDelegate.onFinish = completion
        let videoRecordingURL = getDocumentsDirectory().appendingPathComponent("video.mov")
        videoOutput.startRecording(to: videoRecordingURL, recordingDelegate: videoRecordingDelegate)
    }

    func stopVideoRecording() {
        videoOutput.stopRecording()
    }

    func startAudioRecording() {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("recording.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: AppSettings().micSampleRate,
            AVNumberOfChannelsKey: AppSettings().channelDef,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recordingSession = AVAudioSession.sharedInstance()
            try recordingSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try recordingSession.setActive(true)

            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder.record()
        } catch {
            print("Failed to set up recording session: \(error.localizedDescription)")
        }
    }

    func stopAudioRecording() {
        audioRecorder.stop()
        let audioURL = getDocumentsDirectory().appendingPathComponent("recording.m4a")
        promptSaveAudioToFiles(audioURL: audioURL)
    }

    func takePhoto() {
        guard photoOutput != nil else { return }

        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: photoCaptureDelegate)
    }

    func saveVideoToLibrary(videoURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }, completionHandler: { success, error in
            if let error = error {
                print("Error saving video: \(error.localizedDescription)")
            } else {
                print("Video saved to library")
                if AppSettings().crashAtEnd {
                    exitWithStyle()
                }
            }
        })
    }

    private func deleteOldVideos() {
        let fileManager = FileManager.default
        let videoURL = getDocumentsDirectory().appendingPathComponent("video.mov")
        if fileManager.fileExists(atPath: videoURL.path) {
            try? fileManager.removeItem(at: videoURL)
        }
    }

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    private func promptSaveAudioToFiles(audioURL: URL) {
        let documentPicker = UIDocumentPickerViewController(forExporting: [audioURL])

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootController = scene.windows.first?.rootViewController {
            rootController.present(documentPicker, animated: true, completion: nil)
        }
    }

    func reconfigureCaptureSession() {
        captureSessionQueue.async {
            guard let captureSession = self.captureSession else {
                self.setupCaptureSession()
                return
            }

            captureSession.stopRunning()
            self.captureSession = AVCaptureSession()
            self.setupVideoInput()
            self.setupAudioInput()
            self.setupOutputs()
            self.captureSession.startRunning()
        }
    }

    func hasUltraWideCamera() -> Bool {
        if let ultraWideCamera = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return ultraWideCamera.isConnected
        }
        return false
    }
}
