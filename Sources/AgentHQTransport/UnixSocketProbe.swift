import Darwin
import Foundation

/// Answers one question: is there a live peer on the other end of this unix
/// socket?
///
/// Needed because `ssh -L` creates the local socket file the moment it starts,
/// before — and regardless of whether — the far side is reachable. A tunnel to
/// a host where the remote socket does not exist looks identical on disk to a
/// working one, and even `connect(2)` succeeds against it: ssh accepts the
/// connection, fails to open the far end, and closes the channel. The failure
/// only shows up on the first read.
///
/// So readiness is decided by peeking, not by `stat` and not by `connect`.
enum UnixSocketProbe {
    enum Outcome: Equatable {
        /// Connected, and the peer is holding the connection open. For a
        /// request/response protocol this is exactly what a healthy idle
        /// server looks like: nothing to say until asked.
        case ready
        /// Connected, then immediate EOF — ssh could not reach the far side.
        case peerClosed
        case connectFailed(errno: Int32)
    }

    /// Connect and peek for `timeout` seconds without consuming anything.
    static func probe(path: String, timeout: TimeInterval = 0.25) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .connectFailed(errno: errno) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .connectFailed(errno: ENAMETOOLONG)
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
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while result < 0 && errno == EINTR
        guard result == 0 else { return .connectFailed(errno: errno) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK)
        if peeked == 0 { return .peerClosed }
        if peeked < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return .ready }
        if peeked < 0 { return .peerClosed }
        return .ready
    }
}
