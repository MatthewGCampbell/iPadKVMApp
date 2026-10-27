import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The byte pipe the RFB protocol runs over.
protocol RFBTransport: AnyObject {
    func connect(host: String, port: Int, timeout: TimeInterval) throws
    /// Blocking read. Only ever called from the RFB reader thread.
    func read(exactly count: Int) throws -> Data
    /// Thread-safe; may be called from any thread.
    func send(_ data: Data)
    /// nil disables the timeout.
    func setReadTimeout(_ seconds: TimeInterval?)
    /// Upgrades the connection to TLS in place (VeNCrypt).
    func startTLS() throws
    /// Hex SHA-256 of the peer's leaf certificate once TLS is up.
    func peerCertificateSHA256(waitingUpTo seconds: TimeInterval) -> String?
    func close()
}

/// Plain TCP over BSD sockets. Used for unencrypted connections.
final class SocketTransport: RFBTransport {
    private var fd: Int32 = -1
    private let sendLock = NSLock()
    private var readTimeout: TimeInterval?

    deinit {
        if fd >= 0 { _ = systemClose(fd) }
    }

    func connect(host: String, port: Int, timeout: TimeInterval) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw RFBError.connectionFailed("Can't resolve \(host) (\(String(cString: gai_strerror(rc))))")
        }
        defer { freeaddrinfo(first) }

        var lastError = "no addresses"
        var networkDown = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s < 0 { continue }
            if connectWithTimeout(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen, timeout, &lastError, &networkDown) {
                configure(s)
                fd = s
                return
            }
            _ = systemClose(s)
        }
        if networkDown { throw RFBError.localNetworkDenied }
        throw RFBError.connectionFailed("\(host):\(port) — \(lastError)")
    }

    private func connectWithTimeout(_ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t,
                                    _ timeout: TimeInterval, _ error: inout String, _ networkDown: inout Bool) -> Bool {
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }

        if systemConnect(s, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else {
            if errno == ENETDOWN { networkDown = true }
            error = String(cString: strerror(errno))
            return false
        }
        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        if ready <= 0 {
            error = "timed out"
            return false
        }
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        if soError != 0 {
            if soError == ENETDOWN { networkDown = true }
            error = String(cString: strerror(soError))
            return false
        }
        return true
    }

    private func configure(_ s: Int32) {
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, size)
        setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, size)
        #if canImport(Darwin)
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        #endif
    }

    func setReadTimeout(_ seconds: TimeInterval?) {
        readTimeout = seconds
        guard fd >= 0 else { return }
        let t = seconds ?? 0
        var tv = timeval()
        tv.tv_sec = Int(t)
        tv.tv_usec = .init(Int((t - Double(Int(t))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func read(exactly count: Int) throws -> Data {
        guard fd >= 0 else { throw RFBError.connectionClosed }
        var out = Data(count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { buf -> Int in
                recv(fd, buf.baseAddress! + got, count - got, 0)
            }
            if n > 0 {
                got += n
            } else if n == 0 {
                throw RFBError.connectionClosed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw RFBError.timeout
            } else {
                throw RFBError.connectionFailed(String(cString: strerror(errno)))
            }
        }
        return out
    }

    func send(_ data: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard fd >= 0 else { return }
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = systemSend(fd, buf.baseAddress! + sent, buf.count - sent, flags)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    // The reader thread will notice the broken connection.
                    shutdown(fd, Int32(SHUT_RDWR))
                    return
                }
            }
        }
    }

    func startTLS() throws {
        throw RFBError.unsupported("TLS is not available on this transport.")
    }

    func peerCertificateSHA256(waitingUpTo seconds: TimeInterval) -> String? { nil }

    func close() {
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
    }
}

// Disambiguate libc calls from the methods above.
private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private func systemConnect(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, addr, len)
    #else
    return Glibc.connect(fd, addr, len)
    #endif
}

private func systemSend(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, buf, len, flags)
    #else
    return Glibc.send(fd, buf, len, flags)
    #endif
}
