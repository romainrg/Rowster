import XCTest
@testable import RowsterCore

final class SSHTunnelTests: XCTestCase {
    private func configuration(host: String = "bastion", targetHost: String = "db.internal", user: String = "") -> SSHTunnelConfiguration {
        SSHTunnelConfiguration(host: host, user: user, targetHost: targetHost, targetPort: 5432)
    }

    func testArguments() throws {
        var full = SSHTunnelConfiguration(
            host: "bastion.example.com", port: 2222, user: "deploy", identityFile: "/keys/id_ed25519", targetHost: "db.internal", targetPort: 5432)
        full.extraOptions = ["IdentityAgent=none"]
        XCTAssertEqual(
            try full.arguments(socketPath: "/tmp/rw-1/s", batchMode: true),
            [
                "-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes", "-o", "IdentityAgent=none", "-p", "2222", "-l", "deploy",
                "-i", "/keys/id_ed25519", "-L", "/tmp/rw-1/s:db.internal:5432", "--", "bastion.example.com"
            ])
        let minimal = try configuration().arguments(socketPath: "/s", batchMode: false)
        XCTAssertFalse(minimal.contains("BatchMode=yes"))
        XCTAssertFalse(minimal.contains("-p"))
        XCTAssertEqual(minimal.suffix(4), ["-L", "/s:db.internal:5432", "--", "bastion"])
        XCTAssertTrue(try configuration(targetHost: "::1").arguments(socketPath: "/s", batchMode: true).contains("/s:[::1]:5432"))
    }

    /// A host, a user or a target must never be read by ssh as an option or as a second argument.
    func testHostileValuesAreRefused() {
        for host in ["-oProxyCommand=touch /tmp/pwned", "", "bastion extra", "bastion\n-oProxyCommand=x", " "] {
            XCTAssertThrowsError(try configuration(host: host).arguments(socketPath: "/s", batchMode: true), host) {
                XCTAssertEqual($0 as? SSHTunnelError, .invalid(host))
            }
        }
        for target in ["-oProxyCommand=x", "db internal", "db]:1:evil", "/var/run/socket", ""] {
            XCTAssertThrowsError(try configuration(targetHost: target).arguments(socketPath: "/s", batchMode: true), target)
        }
        XCTAssertThrowsError(try configuration(user: "-oProxyCommand=x").arguments(socketPath: "/s", batchMode: true))
        XCTAssertThrowsError(try configuration(user: "a b").arguments(socketPath: "/s", batchMode: true))
        var badPort = configuration()
        badPort.targetPort = 0
        XCTAssertThrowsError(try badPort.arguments(socketPath: "/s", batchMode: true))
    }

    func testConfigurationFromAProfile() throws {
        var profile = ConnectionProfile(name: "p", engine: .postgres)
        profile.host = "db.internal"
        profile.ssh.isEnabled = true
        profile.ssh.host = " bastion "
        profile.ssh.user = "deploy"
        let configuration = try SSHTunnelConfiguration(profile: profile)
        XCTAssertEqual(configuration.host, "bastion")
        XCTAssertEqual(configuration.targetHost, "db.internal")
        XCTAssertEqual(configuration.targetPort, 5432)
        profile.port = 6543
        XCTAssertEqual(try SSHTunnelConfiguration(profile: profile).targetPort, 6543)
    }

    func testAskpassRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rw-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("a").path

        let asked = Asked()
        let server = try XCTUnwrap(AskpassServer(socketPath: path) { request in
            asked.record(request)
            return request.kind == .confirm ? nil : "s3cret é"
        })
        defer { server.stop() }

        let secret = await Task.detached {
            AskpassClient.ask(socketPath: path, request: AskpassRequest(prompt: "Enter passphrase for key 'id': ", kind: .secret))
        }.value
        XCTAssertEqual(secret, "s3cret é")
        let refused = await Task.detached {
            AskpassClient.ask(socketPath: path, request: AskpassRequest(prompt: "Continue connecting (yes/no)?", kind: .confirm))
        }.value
        XCTAssertNil(refused)
        XCTAssertEqual(asked.all.map(\.prompt), ["Enter passphrase for key 'id': ", "Continue connecting (yes/no)?"])
        XCTAssertEqual(asked.all.map(\.kind), [.secret, .confirm])

        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertNil(AskpassClient.ask(socketPath: directory.appendingPathComponent("missing").path, request: AskpassRequest(prompt: "x", kind: .secret)))
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AskpassRequest] = []
        func record(_ request: AskpassRequest) { lock.withLock { requests.append(request) } }
        var all: [AskpassRequest] { lock.withLock { requests } }
    }

    func testSessionOpensTheTunnelBeforeConnectingAndClosesItAfter() async throws {
        let tunnels = RecordingTunnels()
        let provider = MemoryProvider()
        var profile = ConnectionProfile(name: "p", engine: .postgres)
        profile.host = "db.internal"
        profile.ssh.isEnabled = true
        profile.ssh.host = "bastion"
        let session = Session(profile: profile, password: nil, provider: provider, tunnels: tunnels)
        try await session.open()
        XCTAssertEqual(tunnels.opened, 1)
        XCTAssertEqual(provider.requests.sockets, ["/tmp/recorded.sock"])
        _ = try await session.namespaces()
        XCTAssertEqual(provider.requests.sockets, ["/tmp/recorded.sock", "/tmp/recorded.sock"])
        try await session.switchDatabase("other")
        XCTAssertEqual(tunnels.opened, 1)
        XCTAssertEqual(tunnels.closed, 0)
        await session.close()
        XCTAssertEqual(tunnels.closed, 1)

        let noTunnels = Session(profile: profile, password: nil, provider: provider)
        do {
            try await noTunnels.open()
            XCTFail("connected directly although the profile asks for a tunnel")
        } catch let error as ConnectionError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
    }
}

final class RecordingTunnels: TunnelProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (opened: 0, closed: 0)
    var opened: Int { lock.withLock { counts.opened } }
    var closed: Int { lock.withLock { counts.closed } }

    struct Recorded: Tunnel {
        let socketPath = "/tmp/recorded.sock"
        let onClose: @Sendable () -> Void
        func close() { onClose() }
    }

    func openTunnel(for profile: ConnectionProfile, prompt: AskpassHandler?) async throws -> any Tunnel {
        lock.withLock { counts.opened += 1 }
        return Recorded { [weak self] in self?.lock.withLock { self?.counts.closed += 1 } }
    }
}

/// Runs against the sshd and PostgreSQL servers of `scripts/integration-servers.sh`. Only with `make integration`.
final class SSHIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROWSTER_INTEGRATION"] == "1", "run with make integration")
    }

    private func configuration(targetPort: Int) -> SSHTunnelConfiguration {
        let keys = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/integration/ssh").path
        var configuration = SSHTunnelConfiguration(
            host: "127.0.0.1", port: 22229, identityFile: keys + "/id_ed25519", targetHost: "127.0.0.1", targetPort: targetPort)
        configuration.extraOptions = [
            "IdentitiesOnly=yes", "IdentityAgent=none", "UserKnownHostsFile=\(keys)/known_hosts", "StrictHostKeyChecking=accept-new"
        ]
        return configuration
    }

    func testPostgresWithTLSThroughTheTunnel() async throws {
        let tunnel = try await SSHTunnel.open(configuration(targetPort: 54329), askpassExecutable: nil, prompt: nil, timeout: 20)
        XCTAssertTrue(tunnel.isRunning)
        var server = PostgresIntegrationTests.configuration(user: "rowster_tls", tls: .required)
        server.endpoint = .unix(path: tunnel.socketPath)

        // Several connections share the one ssh process.
        let first = PostgresDriver(configuration: server)
        let second = PostgresDriver(configuration: server)
        try await first.connect()
        try await second.connect()
        let encrypted = try await first.query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        XCTAssertEqual(encrypted.rows, [[.bool(true)]])
        let other = try await second.query("SELECT 2")
        XCTAssertEqual(other.rows, [[.integer(2)]])
        await first.close()
        await second.close()

        tunnel.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(tunnel.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tunnel.socketPath))
    }

    func testAnUnreachableBastionFailsWithWhatSSHSaid() async throws {
        var configuration = configuration(targetPort: 54329)
        configuration.port = 1
        do {
            _ = try await SSHTunnel.open(configuration, askpassExecutable: nil, prompt: nil, timeout: 20)
            XCTFail("opened a tunnel through a closed port")
        } catch let error as SSHTunnelError {
            guard case .failed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.lowercased().contains("connection refused"), message)
        }
    }
}
