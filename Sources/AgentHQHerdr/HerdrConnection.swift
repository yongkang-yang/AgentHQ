import Darwin
import Foundation

// MARK: - HerdrProtocolError

public enum HerdrProtocolError: Error, Sendable, CustomStringConvertible {
    case connectFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case closedBeforeReply
    case oversizeLine(bytes: Int)
    case malformedJSON(String)
    case herdr(code: String, message: String)

    public var description: String {
        switch self {
        case .connectFailed(let path, let e):
            return "Cannot connect to \(path): \(String(cString: strerror(e)))"
        case .writeFailed(let e):
            return "Write failed: \(String(cString: strerror(e)))"
        case .closedBeforeReply:
            return "herdr closed the connection before replying"
        case .oversizeLine(let bytes):
            return "Reply line exceeded \(bytes) bytes"
        case .malformedJSON(let detail):
            return "Malformed reply: \(detail)"
        case .herdr(let code, let message):
            return "herdr error \(code): \(message)"
        }
    }
}

// MARK: - HerdrConnection

/// One connection to a herdr socket, speaking newline-delimited JSON-RPC.
///
/// **herdr serves one request per connection.** Measured against herdr 0.9.0 /
/// protocol 22: the server writes its reply and immediately closes, and a
/// second request on the same socket dies with EPIPE. So a request is a
/// connection — there is no pool to manage, no transaction lock, and no way
/// for two requests to interleave on one fd.
///
/// The exception is `events.subscribe`, which holds the connection open and
/// streams. That one gets its own long-lived `HerdrConnection`, which is what
/// ``LiveHerdrClient`` does.
///
/// (Shepherd's adapter keeps two persistent sockets and serializes requests on
/// one of them. That design answers a protocol-17 problem which protocol 22
/// does not have.)
final class HerdrConnection {
    private var fd: Int32 = -1
    private var readBuffer = Data()

    /// A herdr snapshot of a busy session runs to tens of kilobytes. A cap
    /// well above that turns a runaway or hostile peer into an error instead
    /// of unbounded memory growth.
    static let maxLineBytes = 8 * 1024 * 1024

    init(path: String, timeoutSeconds: Int) throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw HerdrProtocolError.connectFailed(path: path, errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s)
            throw HerdrProtocolError.connectFailed(path: path, errno: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            bytes.withUnsafeBufferPointer { src in
                UnsafeMutableRawPointer(dst).copyMemory(
                    from: UnsafeRawPointer(src.baseAddress!), byteCount: bytes.count
                )
            }
        }

        var result: Int32 = -1
        repeat {
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while result < 0 && errno == EINTR
        guard result == 0 else {
            let e = errno
            close(s)
            throw HerdrProtocolError.connectFailed(path: path, errno: e)
        }

        // `0` means block indefinitely, which is what a subscription wants:
        // its stream is push-based and legitimately silent between events.
        if timeoutSeconds > 0 {
            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        fd = s
    }

    deinit { closeSocket() }

    func closeSocket() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    // MARK: I/O

    func write(_ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HerdrProtocolError.writeFailed(errno: errno)
                }
                if n == 0 { throw HerdrProtocolError.closedBeforeReply }
                sent += n
            }
        }
    }

    /// Read one newline-terminated line, or nil at EOF.
    func readLine() throws -> Data? {
        while true {
            if let index = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[readBuffer.startIndex..<index]
                readBuffer.removeSubrange(readBuffer.startIndex...index)
                return Data(line)
            }
            guard readBuffer.count <= Self.maxLineBytes else {
                throw HerdrProtocolError.oversizeLine(bytes: Self.maxLineBytes)
            }

            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw HerdrProtocolError.writeFailed(errno: errno)
            }
            if n == 0 {
                return readBuffer.isEmpty ? nil : {
                    let rest = Data(readBuffer)
                    readBuffer.removeAll()
                    return rest
                }()
            }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }
}
