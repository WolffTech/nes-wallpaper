import Foundation

/// UDP heartbeat receiver: the screensaver sends a datagram to
/// 127.0.0.1:<port> about once a second while it is animating, and the app
/// treats "datagram within maxAge" as the saver being on screen.
///
/// UDP over loopback, not a file: the saver can only write inside the
/// legacyScreenSaver container, and macOS app-container protection denies
/// other processes (the app included) even reading it — a file heartbeat
/// there is invisible to us. The saver's host does hold the network-client
/// entitlement.
public final class HeartbeatListener {
    /// Bound port, published to the saver via the manifest.
    public let port: UInt16
    /// Called on the main queue for every datagram, so the owner can react
    /// immediately instead of waiting for its next staleness poll.
    public var onBeat: (() -> Void)?

    private let source: DispatchSourceRead
    private let maxAge: TimeInterval
    private var lastBeat = Date.distantPast

    public init?(maxAge: TimeInterval = 4) {
        self.maxAge = maxAge
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1") // loopback only
        addr.sin_port = 0                             // ephemeral
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard bound, addr.sin_port != 0 else {
            close(fd)
            return nil
        }
        port = UInt16(bigEndian: addr.sin_port)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            var scratch = [UInt8](repeating: 0, count: 16)
            guard recv(fd, &scratch, scratch.count, 0) > 0 else { return }
            guard let self else { return }
            self.lastBeat = Date()
            self.onBeat?()
        }
        source.resume()
    }

    deinit { source.cancel() }

    public var saverActive: Bool {
        Date().timeIntervalSince(lastBeat) <= maxAge
    }
}
