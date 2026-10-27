#if canImport(Darwin)
import Foundation
import Security
import CryptoKit

/// TCP via Foundation streams, which (unlike Network.framework) can be upgraded
/// to TLS in the middle of a connection — exactly what VeNCrypt needs.
///
/// All stream work happens on a private run-loop thread; the protocol thread
/// reads from `incoming` and writes are handed to the I/O thread.
final class StreamTransport: NSObject, RFBTransport, StreamDelegate {
    private var input: InputStream?
    private var output: OutputStream?
    private var runLoop: CFRunLoop?
    private let incoming = ByteQueue()
    private var pending = Data()  // I/O thread only
    private var readTimeout: TimeInterval?

    private let stateLock = NSLock()
    private var finished = false
    private var openSignalled = false
    private var openError: Error?
    private let openSignal = DispatchSemaphore(value: 0)

    private var isFinished: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return finished
    }

    func connect(host: String, port: Int, timeout: TimeInterval) throws {
        var i: InputStream?
        var o: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &i, outputStream: &o)
        guard let i, let o else { throw RFBError.connectionFailed("Can't create a connection to \(host)") }
        input = i
        output = o

        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            i.delegate = self
            o.delegate = self
            i.schedule(in: .current, forMode: .default)
            o.schedule(in: .current, forMode: .default)
            i.open()
            o.open()
            started.signal()
            while !isFinished {
                autoreleasepool {
                    _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
                }
            }
            i.close()
            o.close()
            i.remove(from: .current, forMode: .default)
            o.remove(from: .current, forMode: .default)
        }
        thread.name = "VNC I/O"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()

        if openSignal.wait(timeout: .now() + timeout) == .timedOut {
            close()
            throw RFBError.connectionFailed("\(host):\(port) — timed out")
        }
        stateLock.lock()
        let error = openError
        stateLock.unlock()
        if let error {
            close()
            if RFBError.isNetworkDown(error) { throw RFBError.localNetworkDenied }
            throw RFBError.connectionFailed("\(host):\(port) — \(error.localizedDescription)")
        }
    }

    // MARK: Thread hopping

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func performSync<T>(_ block: @escaping () -> T) -> T? {
        guard runLoop != nil, !isFinished else { return nil }
        let done = DispatchSemaphore(value: 0)
        var result: T?
        perform {
            result = block()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut { return nil }
        return result
    }

    // MARK: RFBTransport

    func setReadTimeout(_ seconds: TimeInterval?) { readTimeout = seconds }

    func read(exactly count: Int) throws -> Data {
        try incoming.read(exactly: count, deadline: readTimeout.map { Date(timeIntervalSinceNow: $0) })
    }

    func send(_ data: Data) {
        perform { [self] in
            pending.append(data)
            flush()
        }
    }

    func startTLS() throws {
        let ok = performSync { [self] () -> Bool in
            guard let input else { return false }
            // PiKVM uses a self-signed certificate, so the chain can't be validated.
            // Instead we pin the certificate's fingerprint on first use (see RFBClient).
            let settings: [String: Any] = [
                kCFStreamSSLValidatesCertificateChain as String: kCFBooleanFalse as Any,
                kCFStreamSSLPeerName as String: kCFNull as Any,
            ]
            // Setting this on one stream of an open pair starts the handshake for both.
            return input.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
        }
        guard ok == true else { throw RFBError.unsupported("Couldn't start TLS on this connection.") }
    }

    func peerCertificateSHA256(waitingUpTo seconds: TimeInterval) -> String? {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            let fingerprint = performSync { [self] () -> String? in
                guard let input else { return nil }
                let key = Stream.PropertyKey(kCFStreamPropertySSLPeerTrust as String)
                guard let value = input.property(forKey: key) else { return nil }
                let ref = value as CFTypeRef
                guard CFGetTypeID(ref) == SecTrustGetTypeID() else { return nil }
                let trust = ref as! SecTrust
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else { return nil }
                let der = SecCertificateCopyData(leaf) as Data
                return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            } ?? nil
            if let fingerprint { return fingerprint }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    func close() {
        fail(nil)
    }

    // MARK: Stream events (I/O thread)

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted:
            if stream === output {
                disableNagle()
                signalOpen(nil)
            }
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            fail(stream.streamError ?? RFBError.connectionClosed)
        case .endEncountered:
            fail(RFBError.connectionClosed)
        default:
            break
        }
    }

    /// Without TCP_NODELAY, small packets (key presses, pointer moves) can sit in the
    /// kernel for up to ~200 ms waiting to be batched — very visible as input lag.
    private func disableNagle() {
        // Unlike the SSL keys, this one is imported as an optional CFStreamPropertyKey.
        guard let cfKey = kCFStreamPropertySocketNativeHandle else { return }
        let key = Stream.PropertyKey(rawValue: cfKey.rawValue as String)
        guard let handle = output?.property(forKey: key) as? Data,
              handle.count >= MemoryLayout<Int32>.size else { return }
        let fd = handle.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func readAvailable() {
        guard let input else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let n = input.read(&buffer, maxLength: buffer.count)
        if n > 0 {
            incoming.append(Data(buffer[0..<n]))
        } else if n == 0 {
            fail(RFBError.connectionClosed)
        } else {
            fail(input.streamError ?? RFBError.connectionClosed)
        }
    }

    private func flush() {
        guard let output else { return }
        while !pending.isEmpty && output.hasSpaceAvailable {
            let n = pending.withUnsafeBytes { buf -> Int in
                output.write(buf.bindMemory(to: UInt8.self).baseAddress!, maxLength: buf.count)
            }
            if n < 0 {
                fail(output.streamError ?? RFBError.connectionClosed)
                return
            }
            if n == 0 { break }
            pending = Data(pending.dropFirst(n))
        }
    }

    private func signalOpen(_ error: Error?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !openSignalled else { return }
        openSignalled = true
        openError = error
        openSignal.signal()
    }

    private func fail(_ error: Error?) {
        signalOpen(error ?? RFBError.connectionClosed)
        incoming.close(error: error)
        stateLock.lock()
        finished = true
        stateLock.unlock()
        if let runLoop { CFRunLoopWakeUp(runLoop) }
    }
}
#endif
