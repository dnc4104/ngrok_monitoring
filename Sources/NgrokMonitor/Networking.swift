import Darwin
import Foundation

/// Quick non-blocking TCP probe to 127.0.0.1:<port>. Used to avoid the
/// noisy URLSession "Connection refused" log spam when ngrok isn't running.
func isLocalPortOpen(_ port: UInt16, timeoutMs: Int32 = Constants.Timeout.portProbeMs) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connectResult == 0 { return true }
    if errno != EINPROGRESS { return false }

    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let polled = poll(&pfd, 1, timeoutMs)
    if polled <= 0 { return false }

    var soErr: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) < 0 { return false }
    return soErr == 0
}
