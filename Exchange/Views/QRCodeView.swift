//
//  QRCodeView.swift
//  Exchange
//
//  Renders an arbitrary string as a square QR code using CoreImage.
//
//  Used by MyIdentityQRView (to show the user's own public key) and
//  potentially anywhere we want to share a piece of text "in person".
//
//  Why interpolation(.none): QR codes are pixel art. The default linear
//  interpolation blurs the modules and confuses some scanner apps; nearest
//  neighbour keeps the modules crisp at any size.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct QRCodeView: View {
    let payload: String

    /// Error-correction level. "M" (~15%) is a good default — balances
    /// scanability with a small enough QR for short payloads like a
    /// 44-character base64 public key.
    var correctionLevel: CorrectionLevel = .medium

    enum CorrectionLevel: String {
        case low = "L"      // ~7%
        case medium = "M"   // ~15%
        case quartile = "Q" // ~25%
        case high = "H"     // ~30%
    }

    var body: some View {
        Group {
            if let image = generate() {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel("QR code")
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("QR code couldn't be generated")
            }
        }
    }

    /// Generate a UIImage for the payload. Returns nil if CoreImage fails
    /// to produce an image (extremely rare — only happens for empty input
    /// or pathological filter state).
    private func generate() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel.rawValue
        guard let ciImage = filter.outputImage else { return nil }
        // Scale up so the modules render at a reasonable pixel size when
        // shown on a phone screen. The view modifiers handle final layout
        // sizing; this just ensures we hand SwiftUI enough resolution.
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    QRCodeView(payload: "gN1XmeTKJ4n4S5xXuNAwYscRZGvI3ULpcvFMrQS9bI8gN1XmeTKJ4n4S5xXuNAwYscRZGvI3ULpcvFMrQS9bI8=")
        .frame(width: 240, height: 240)
        .padding()
}
