import CoreGraphics
import Foundation
import ImageIO

/// The remote screen's pixels. Written by the RFB reader thread, read by the UI.
///
/// PiKVM sends every frame as one full-screen JPEG, so the common path just keeps
/// the decoded image. Partial updates (other VNC servers) are drawn into a bitmap context.
final class Framebuffer: RFBFramebufferSink {
    /// Called on the reader thread when there's a new frame to show and none is pending.
    var onUpdate: (@Sendable () -> Void)?
    var onResize: (@Sendable (Int, Int) -> Void)?

    private let lock = NSLock()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private var context: CGContext?
    private var fullFrame: CGImage?
    /// True when `fullFrame` is newer than `context`.
    private var contextIsStale = false
    private var dirty = false
    private var displayPending = false
    private var frameCounter = 0
    private(set) var width = 0
    private(set) var height = 0

    // MARK: UI side

    /// The latest frame for display; also re-arms `onUpdate`.
    func imageForDisplay() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        displayPending = false
        return currentImage()
    }

    func snapshot() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return currentImage()
    }

    func takeFrameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = frameCounter
        frameCounter = 0
        return n
    }

    private func currentImage() -> CGImage? {
        if contextIsStale { return fullFrame }
        return context?.makeImage()
    }

    // MARK: RFBFramebufferSink (reader thread)

    func rfbResize(width: Int, height: Int) {
        lock.lock()
        self.width = width
        self.height = height
        context = makeContext(width: width, height: height)
        fullFrame = nil
        contextIsStale = false
        lock.unlock()
        onResize?(width, height)
    }

    func rfbJPEG(_ data: Data, x: Int, y: Int, width w: Int, height h: Int) {
        // Decode before taking the lock so the UI never waits on JPEG decoding.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return }

        lock.lock()
        defer { lock.unlock() }
        if x == 0 && y == 0 && w == width && h == height {
            fullFrame = image
            contextIsStale = true
        } else {
            syncContext()
            context?.draw(image, in: cgRect(x, y, w, h))
        }
        dirty = true
    }

    func rfbFill(x: Int, y: Int, width w: Int, height h: Int, red: UInt8, green: UInt8, blue: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        syncContext()
        guard let context else { return }
        context.setBlendMode(.copy)
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(cgRect(x, y, w, h))
        dirty = true
    }

    func rfbRaw(_ pixels: Data, x: Int, y: Int, width w: Int, height h: Int) {
        guard w > 0, h > 0, let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        syncContext()
        context?.setBlendMode(.copy)
        context?.draw(image, in: cgRect(x, y, w, h))
        dirty = true
    }

    func rfbCopy(srcX: Int, srcY: Int, x: Int, y: Int, width w: Int, height h: Int) {
        lock.lock()
        defer { lock.unlock() }
        syncContext()
        // CGImage cropping uses top-left origin, like RFB.
        guard let context, let region = context.makeImage()?.cropping(to: CGRect(x: srcX, y: srcY, width: w, height: h))
        else { return }
        context.setBlendMode(.copy)
        context.draw(region, in: cgRect(x, y, w, h))
        dirty = true
    }

    func rfbUpdateComplete() {
        lock.lock()
        let notify = dirty && !displayPending
        if dirty { frameCounter += 1 }
        if notify { displayPending = true }
        dirty = false
        lock.unlock()
        if notify { onUpdate?() }
    }

    // MARK: Helpers (call with lock held)

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
        ctx?.interpolationQuality = .none
        ctx?.setFillColor(gray: 0, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Before a partial update, bring the bitmap context up to date with the last full frame.
    private func syncContext() {
        guard contextIsStale else { return }
        if let fullFrame, let context {
            context.setBlendMode(.copy)
            context.draw(fullFrame, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        fullFrame = nil
        contextIsStale = false
    }

    /// RFB rects are top-left based; Core Graphics is bottom-left.
    private func cgRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: x, y: height - y - h, width: w, height: h)
    }
}
