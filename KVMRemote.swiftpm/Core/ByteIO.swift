import Foundation

/// Big-endian helpers for building RFB messages.
extension Data {
    mutating func appendU8(_ v: UInt8) { append(v) }

    mutating func appendU16(_ v: UInt16) {
        append(UInt8(v >> 8))
        append(UInt8(v & 0xFF))
    }

    mutating func appendU32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendS32(_ v: Int32) { appendU32(UInt32(bitPattern: v)) }

    mutating func appendPadding(_ count: Int) { append(contentsOf: [UInt8](repeating: 0, count: count)) }
}

/// A thread-safe FIFO of bytes with blocking reads. One thread produces
/// (the network I/O thread), one thread consumes (the RFB protocol thread).
final class ByteQueue {
    private let condition = NSCondition()
    private var buffer = Data()
    /// Bytes before this index have been consumed; compacted lazily.
    private var readIndex = 0
    private var closedError: Error?
    private var isClosed = false

    func append(_ data: Data) {
        condition.lock()
        if readIndex > 0 && readIndex >= buffer.count / 2 {
            buffer = Data(buffer[(buffer.startIndex + readIndex)...])
            readIndex = 0
        }
        buffer.append(data)
        condition.broadcast()
        condition.unlock()
    }

    func close(error: Error?) {
        condition.lock()
        if !isClosed {
            isClosed = true
            closedError = error
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until `count` bytes are available, the queue is closed, or the deadline passes.
    func read(exactly count: Int, deadline: Date?) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while buffer.count - readIndex < count {
            if isClosed { throw closedError ?? RFBError.connectionClosed }
            if let deadline {
                if !condition.wait(until: deadline) && buffer.count - readIndex < count {
                    throw RFBError.timeout
                }
            } else {
                condition.wait()
            }
        }
        let start = buffer.startIndex + readIndex
        let out = Data(buffer[start..<(start + count)])
        readIndex += count
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        }
        return out
    }
}
