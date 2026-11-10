import Foundation

/// A question OpenSSH asks the user: a passphrase, a password, or whether to trust a host key.
public struct AskpassRequest: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        /// The answer must not be shown while typed.
        case secret = 1
        /// A yes/no question, such as accepting a new host key.
        case confirm = 2
        /// Information only.
        case info = 3
    }

    public var prompt: String
    public var kind: Kind

    public init(prompt: String, kind: Kind) {
        self.prompt = prompt
        self.kind = kind
    }
}

/// Answers a question; `nil` cancels. The answer is passed to OpenSSH and is never stored or logged.
public typealias AskpassHandler = @Sendable (AskpassRequest) async -> String?

/// Unix-domain socket plumbing shared by the askpass server and its client.
enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    static func readExactly(_ descriptor: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + offset, count - offset) }
            if got <= 0 { return nil }
            offset += got
        }
        return data
    }

    @discardableResult
    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, data.count - offset) }
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }

    static func frame(_ marker: UInt8, _ text: String) -> Data {
        let body = Data(text.utf8)
        var data = Data([marker])
        data.appendBE(Int32(clamping: body.count))
        data.append(body)
        return data
    }

    static func readFrame(_ descriptor: Int32) -> (marker: UInt8, text: String)? {
        guard let header = readExactly(descriptor, 5) else { return nil }
        var reader = ByteReader(header)
        let marker = reader.byte()
        let length = Int(reader.int32BE())
        guard length >= 0, length <= 1 << 20 else { return nil }
        guard length > 0 else { return (marker, "") }
        guard let body = readExactly(descriptor, length) else { return nil }
        return (marker, String(decoding: body, as: UTF8.self))
    }
}

/// Listens on a private Unix socket for the questions of the askpass helper, and answers them through
/// the handler. One server lives as long as its tunnel is being opened.
public final class AskpassServer: @unchecked Sendable {
    public let socketPath: String
    private let descriptor: Int32
    private let handler: AskpassHandler

    public init?(socketPath: String, handler: @escaping AskpassHandler) {
        guard var address = UnixSocket.address(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.socketPath = socketPath
        self.descriptor = descriptor
        self.handler = handler
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "io.github.romainrg.Rowster.askpass"
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            guard let frame = UnixSocket.readFrame(client), let kind = AskpassRequest.Kind(rawValue: frame.marker) else {
                Darwin.close(client)
                continue
            }
            let handler = handler
            Task {
                let answer = await handler(AskpassRequest(prompt: frame.text, kind: kind))
                UnixSocket.writeAll(client, UnixSocket.frame(answer == nil ? 0 : 1, answer ?? ""))
                Darwin.close(client)
            }
        }
    }

    public func stop() {
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        unlink(socketPath)
    }
}

/// The side that runs inside the askpass helper process started by OpenSSH.
public enum AskpassClient {
    public static let socketVariable = "ROWSTER_ASKPASS_SOCKET"

    /// Sends a question to the app and waits for the answer; `nil` when it was cancelled or the app is gone.
    public static func ask(socketPath: String, request: AskpassRequest) -> String? {
        guard var address = UnixSocket.address(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, UnixSocket.writeAll(descriptor, UnixSocket.frame(request.kind.rawValue, request.prompt)),
              let answer = UnixSocket.readFrame(descriptor), answer.marker == 1 else { return nil }
        return answer.text
    }

    /// The whole job of the helper: forward the prompt OpenSSH gave on the command line, print the answer.
    /// Returns the exit status: OpenSSH reads a non-zero status as a refusal.
    public static func runHelper(
        socketPath: String, arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        let kind: AskpassRequest.Kind
        switch environment["SSH_ASKPASS_PROMPT"] {
        case "confirm": kind = .confirm
        case "none": kind = .info
        default: kind = .secret
        }
        let prompt = arguments.dropFirst().joined(separator: " ")
        guard let answer = ask(socketPath: socketPath, request: AskpassRequest(prompt: prompt, kind: kind)) else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }
}
