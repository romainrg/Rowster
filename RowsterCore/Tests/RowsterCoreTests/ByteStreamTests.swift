import Network
import XCTest
@testable import RowsterCore

/// A listener on 127.0.0.1 that sends back what it receives, prefixed with a greeting.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rowster.test.echo")
    let greeting: Data

    init(greeting: Data = Data()) throws {
        self.greeting = greeting
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            listener.newConnectionHandler = { [greeting, queue] connection in
                connection.start(queue: queue)
                if !greeting.isEmpty { connection.send(content: greeting, completion: .contentProcessed { _ in }) }
                Self.echo(connection)
            }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in echo(connection) })
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    func stop() { listener.cancel() }
}

final class ByteStreamTests: XCTestCase {
    func testReadsAndWritesAcrossChunks() async throws {
        let server = try EchoServer(greeting: Data("hello ".utf8))
        let port = try await server.start()
        defer { server.stop() }

        let stream = ByteStream(endpoint: .tcp(host: "127.0.0.1", port: port))
        try await stream.open()
        XCTAssertFalse(stream.isEncrypted)
        let greeting = try await stream.read(exactly: 6)
        XCTAssertEqual(greeting, Data("hello ".utf8))

        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        try await stream.write(payload)
        var received = Data()
        for size in [1, 4, 999, 65_536, 200_000 - 66_540] {
            received.append(try await stream.read(exactly: size))
        }
        XCTAssertEqual(received, payload)
        stream.close()
    }

    func testConnectionRefused() async {
        let stream = ByteStream(endpoint: .tcp(host: "127.0.0.1", port: 1))
        do {
            try await stream.open()
            XCTFail("connected to a closed port")
        } catch let error as ConnectionError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testReadAfterTheServerClosesFails() async throws {
        let server = try EchoServer()
        let port = try await server.start()
        let stream = ByteStream(endpoint: .tcp(host: "127.0.0.1", port: port))
        try await stream.open()
        stream.close()
        do {
            _ = try await stream.read(exactly: 1)
            XCTFail("read from a closed stream")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .closed)
        }
        server.stop()
    }

    func testRequiredTLSFailsAgainstAServerThatRefusesIt() async throws {
        // The echo server answers the SSLRequest with 'N', as a PostgreSQL server without TLS does.
        let server = try EchoServer(greeting: Data("N".utf8))
        let port = try await server.start()
        defer { server.stop() }

        let required = ByteStream(endpoint: .tcp(host: "127.0.0.1", port: port), tls: TLSSettings(mode: .required), upgrade: .postgres)
        do {
            try await required.open()
            XCTFail("opened without TLS although TLS is required")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .tlsRequiredButUnavailable)
        }

        let preferred = ByteStream(endpoint: .tcp(host: "127.0.0.1", port: port), tls: TLSSettings(mode: .preferred), upgrade: .postgres)
        try await preferred.open()
        XCTAssertFalse(preferred.isEncrypted)
        preferred.close()
    }

    func testMySQLGreetingIsHandedToTheDriver() async throws {
        let payload = Data("greeting-bytes".utf8)
        var packet = Data([UInt8(payload.count), 0, 0, 0])
        packet.append(payload)
        let server = try EchoServer(greeting: packet)
        let port = try await server.start()
        defer { server.stop() }

        let stream = ByteStream(
            endpoint: .tcp(host: "127.0.0.1", port: port), tls: TLSSettings(mode: .preferred),
            upgrade: .mysql(makeRequest: { _ in nil }))
        try await stream.open()
        XCTAssertEqual(stream.greeting, payload)
        XCTAssertFalse(stream.isEncrypted)
        stream.close()
    }
}
