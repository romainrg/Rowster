import Foundation
import Network
import Security

public enum TransportEndpoint: Sendable, Equatable {
    case tcp(host: String, port: Int)
    case unix(path: String)
}

public struct TLSSettings: Sendable, Equatable {
    public var mode: TLSMode
    /// The name the certificate must carry in `verifyIdentity`: the database host, even through a tunnel.
    public var serverName: String
    /// PEM file of the authorities to trust instead of the system ones. Empty to use the system trust store.
    public var caFile: String

    public init(mode: TLSMode, serverName: String = "", caFile: String = "") {
        self.mode = mode
        self.serverName = serverName
        self.caFile = caFile
    }
}

/// How a protocol that starts in clear text switches to TLS.
public enum TLSUpgrade: Sendable {
    /// PostgreSQL: send `SSLRequest`, read one byte.
    case postgres
    /// MySQL: read the server greeting, then send the packet `makeRequest` builds from it.
    /// `makeRequest` returns `nil` when the greeting says the server has no TLS.
    case mysql(makeRequest: @Sendable (Data) -> Data?)
}

/// Shared between a stream and its framer: what to do, and what happened.
private final class UpgradeContext: @unchecked Sendable {
    let upgrade: TLSUpgrade
    let settings: TLSSettings
    var greeting: Data?

    init(upgrade: TLSUpgrade, settings: TLSSettings) {
        self.upgrade = upgrade
        self.settings = settings
    }

    func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let settings = settings
        if !settings.serverName.isEmpty, IPv4Address(settings.serverName) == nil, IPv6Address(settings.serverName) == nil {
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, settings.serverName)
        }
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            guard settings.mode.verifiesCertificate else { return complete(true) }
            complete(Self.isTrusted(sec_trust_copy_ref(trust).takeRetainedValue(), settings: settings))
        }, DispatchQueue.global(qos: .userInitiated))
        return options
    }

    /// `verifyCA` checks the chain; `verifyIdentity` also checks the host name.
    static func isTrusted(_ trust: SecTrust, settings: TLSSettings) -> Bool {
        let policy = settings.mode == .verifyIdentity
            ? SecPolicyCreateSSL(true, settings.serverName as CFString) : SecPolicyCreateBasicX509()
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        if !settings.caFile.isEmpty {
            let anchors = certificates(inPEMFile: settings.caFile)
            guard !anchors.isEmpty, SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func certificates(inPEMFile path: String) -> [SecCertificate] {
        guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return [] }
        var found: [SecCertificate] = []
        var body: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                body = ""
            } else if line.hasPrefix("-----END CERTIFICATE") {
                if let data = body.flatMap({ Data(base64Encoded: $0) }), let certificate = SecCertificateCreateWithData(nil, data as CFData) {
                    found.append(certificate)
                }
                body = nil
            } else {
                body?.append(contentsOf: line.trimmingCharacters(in: .whitespaces))
            }
        }
        return found
    }
}

/// Runs the clear-text part of a connection, then puts TLS above itself and gets out of the way.
private final class TLSUpgradeFramer: NWProtocolFramerImplementation {
    static let label = "RowsterTLSUpgrade"
    static let definition = NWProtocolFramer.Definition(implementation: TLSUpgradeFramer.self)

    init(framer: NWProtocolFramer.Instance) {}

    private func context(_ framer: NWProtocolFramer.Instance) -> UpgradeContext? {
        framer.options["context"] as? UpgradeContext
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        if case .postgres? = context(framer)?.upgrade {
            framer.writeOutput(data: Data([0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F]))
        }
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard let context = context(framer) else {
            finish(framer, tls: nil)
            return 0
        }
        switch context.upgrade {
        case .postgres:
            var answer: UInt8?
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { buffer, _ in
                guard let buffer, buffer.count >= 1 else { return 0 }
                answer = buffer[0]
                return 1
            }
            guard let answer else { return 1 }
            finish(framer, tls: answer == UInt8(ascii: "S") ? context : nil)

        case .mysql(let makeRequest):
            var length: Int?
            _ = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
                guard let buffer, buffer.count >= 4 else { return 0 }
                length = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16
                return 0
            }
            guard let length else { return 4 }
            let total = length + 4
            var greeting: Data?
            _ = framer.parseInput(minimumIncompleteLength: total, maximumLength: total) { buffer, _ in
                guard let buffer, buffer.count >= total, let base = buffer.baseAddress else { return 0 }
                greeting = Data(bytes: base + 4, count: length)
                return total
            }
            guard let greeting else { return total }
            context.greeting = greeting
            if let request = makeRequest(greeting) {
                framer.writeOutput(data: request)
                finish(framer, tls: context)
            } else {
                finish(framer, tls: nil)
            }
        }
        return 0
    }

    private func finish(_ framer: NWProtocolFramer.Instance, tls context: UpgradeContext?) {
        if let context { try? framer.prependApplicationProtocol(options: context.tlsOptions()) }
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.markReady()
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

/// A connection to a database server: bytes in, bytes out, with TLS negotiated as the settings ask.
public final class ByteStream: @unchecked Sendable {
    private let connection: NWConnection
    private let context: UpgradeContext?
    private let settings: TLSSettings
    private let queue = DispatchQueue(label: "io.github.romainrg.Rowster.stream")
    private var buffer = Data()
    private var readIndex = 0
    public private(set) var isEncrypted = false

    public init(endpoint: TransportEndpoint, tls: TLSSettings = TLSSettings(mode: .disabled), upgrade: TLSUpgrade? = nil) {
        settings = tls
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let upgrade, tls.mode != .disabled {
            let context = UpgradeContext(upgrade: upgrade, settings: tls)
            let options = NWProtocolFramer.Options(definition: TLSUpgradeFramer.definition)
            options["context"] = context
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            self.context = context
        } else {
            context = nil
        }
        switch endpoint {
        case .tcp(let host, let port):
            connection = NWConnection(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any, using: parameters)
        case .unix(let path):
            connection = NWConnection(to: .unix(path: path), using: parameters)
        }
    }

    /// The MySQL greeting, when the TLS upgrade had to read it before the driver could.
    public var greeting: Data? { context?.greeting }

    /// Connects and negotiates TLS. Throws when TLS is required and the server does not offer it.
    public func open() async throws {
        let resumed = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.claim() {
                        connection.cancel()
                        continuation.resume(throwing: Self.map(error))
                    }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: ConnectionError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        isEncrypted = connection.metadata(definition: NWProtocolTLS.definition) != nil
        if context != nil, settings.mode.requiresTLS, !isEncrypted {
            close()
            throw ConnectionError.tlsRequiredButUnavailable
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        while buffer.count - readIndex < count {
            let chunk = try await receive()
            if readIndex == buffer.count {
                buffer = chunk
                readIndex = 0
            } else {
                buffer.append(chunk)
            }
        }
        let start = buffer.startIndex + readIndex
        readIndex += count
        return Data(buffer[start..<start + count])
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: Self.map(error))
                } else if isComplete {
                    continuation.resume(throwing: ConnectionError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            })
        }
    }

    public func close() {
        connection.cancel()
    }

    private static func map(_ error: NWError) -> ConnectionError {
        switch error {
        case .posix(let code):
            if code == .ECANCELED || code == .ENOTCONN || code == .ECONNRESET || code == .EPIPE { return .closed }
            return .unreachable(String(cString: strerror(code.rawValue)))
        case .tls(let status):
            return .tlsFailed(SecCopyErrorMessageString(status, nil) as String? ?? "TLS error \(status)")
        case .dns:
            return .unreachable("the host name could not be resolved")
        default:
            return .unreachable(error.localizedDescription)
        }
    }
}

/// Lets exactly one caller through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
