import CoreGraphics
import Vision

/// On-device OCR used to copy text *from* the remote screen. A hardware KVM like
/// PiKVM only sees the video signal, so reading the pixels is the one way to get
/// text back without installing anything on the remote computer.
enum TextRecognizer {
    static func recognizeText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            // Small selections recognise much better when enlarged first.
            let input = image.width < 1200 ? TextRecognizer.upscaled(image, by: 2) ?? image : image
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Keep exactly what's on screen (code, paths, commands) instead of "correcting" it.
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
            return TextRecognizer.layout(request.results ?? [])
        }.value
    }

    /// Joins observations into lines, top to bottom and left to right.
    private static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Fragment { let text: String; let box: CGRect }
        let fragments = observations.compactMap { obs -> Fragment? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return Fragment(text: candidate.string, box: obs.boundingBox)
        }
        // Vision's coordinates have their origin at the bottom left.
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }
        var lines: [[Fragment]] = []
        for fragment in sorted {
            if let last = lines.last?.last,
               abs(last.box.midY - fragment.box.midY) < min(last.box.height, fragment.box.height) * 0.5 {
                lines[lines.count - 1].append(fragment)
            } else {
                lines.append([fragment])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func upscaled(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor
        let height = image.height * factor
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
