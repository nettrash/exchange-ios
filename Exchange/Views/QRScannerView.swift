//
//  QRScannerView.swift
//  Exchange
//
//  Live-camera QR scanner, exposed as a SwiftUI view via
//  UIViewControllerRepresentable.
//
//  The view fires `onScan` with the decoded string the first time it sees
//  a QR, then stops the capture session — no continuous scanning, no
//  multi-result handling, just "give me the next QR you see."
//
//  Errors (no camera, permission denied, AVFoundation misconfig) come
//  back via `onError` so the caller can dismiss the sheet and surface a
//  message. The view itself doesn't render any error UI.
//

import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let viewController = QRScannerViewController()
        viewController.onScan = onScan
        viewController.onError = onError
        return viewController
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // Closures may have changed; refresh them so the view doesn't hold
        // stale references after a parent state change.
        uiViewController.onScan = onScan
        uiViewController.onError = onError
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReportedScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { await requestPermissionAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
    }

    // MARK: - Permission + setup

    private func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                startCapture()
            } else {
                onError?("Camera access is required to scan QR codes. You can enable it in Settings → Exchange → Camera.")
            }
        case .denied, .restricted:
            onError?("Camera access is required to scan QR codes. You can enable it in Settings → Exchange → Camera.")
        @unknown default:
            onError?("Camera access status is unknown.")
        }
    }

    private func startCapture() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("No camera is available on this device.")
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            onError?("Couldn't access the camera: \(error.localizedDescription)")
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onError?("Camera input couldn't be configured.")
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            onError?("Camera output couldn't be configured.")
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)

        captureSession = session
        previewLayer = layer

        // startRunning blocks; do it off the main queue so we don't hitch
        // the presenting transition.
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasReportedScan,
              let codeObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = codeObject.stringValue,
              !value.isEmpty
        else { return }

        hasReportedScan = true
        // Stop the session before invoking the callback so the camera
        // turns off promptly when the parent dismisses the sheet.
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
        onScan?(value)
    }
}
