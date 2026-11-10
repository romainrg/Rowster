import Foundation

/// MySQL and MariaDB over their wire protocol, with no C library.
///
/// What the user types goes through the text protocol. What Rowster generates has bound parameters and
/// goes through prepared statements, so a value is never part of the SQL text.
public final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    public let dialect: any SQLDialect
    private let configuration: ServerConfiguration
    private let engine: Engine
    private var stream: ByteStream?
    private var handshake: MySQLHandshake?
    private var capabilities: UInt32 = 0
    private var sequence: UInt8 = 0
    private var status: UInt16 = 0
    fileprivate var hasOpenCursor = false

    private let lock = NSLock()
    private var threadID: UInt32?

    public init(configuration: ServerConfiguration, engine: Engine = .mysql) {
        self.configuration = configuration
        self.engine = engine
        dialect = MySQLDialect(engine: engine)
    }

    fileprivate var deprecateEOF: Bool { capabilities & MySQLCapability.deprecateEOF != 0 }

    // MARK: - Packets

    fileprivate func readPacket() async throws -> Data {
        guard let stream else { throw ConnectionError.closed }
        var payload = Data()
        while true {
            var header = ByteReader(try await stream.read(exactly: 4))
            let length = Int(header.uintLE(3))
            sequence = header.byte()
            if length > 0 { payload.append(try await stream.read(exactly: length)) }
            if length < MySQLPacket.maxPayload { return payload }
        }
    }

    /// Answers the server inside an exchange: the sequence continues.
    private func reply(_ payload: Data) async throws {
        guard let stream else { throw ConnectionError.closed }
        let framed = MySQLPacket.frame(payload, sequence: sequence &+ 1)
        sequence = framed.next &- 1
        try await stream.write(framed.data)
    }

    /// Starts a new command: the sequence restarts at zero.
    private func command(_ payload: Data) async throws {
        guard let stream else { throw ConnectionError.closed }
        let framed = MySQLPacket.frame(payload, sequence: 0)
        sequence = framed.next &- 1
        try await stream.write(framed.data)
    }

    // MARK: - Connection

    public func connect() async throws {
        let hasDatabase = !configuration.database.isEmpty
        let stream = ByteStream(
            endpoint: configuration.endpoint, tls: configuration.tls,
            upgrade: .mysql(makeRequest: { greeting in
                guard let handshake = MySQLHandshake(greeting), handshake.supportsTLS else { return nil }
                let capabilities = MySQLCapability.client(server: handshake.capabilities, hasDatabase: hasDatabase, tls: true)
                return MySQLPacket.frame(MySQLPacket.sslRequest(capabilities: capabilities), sequence: 1).data
            }))
        try await stream.open()
        self.stream = stream
        do {
            let greeting: Data
            if let alreadyRead = stream.greeting {
                greeting = alreadyRead
                sequence = stream.isEncrypted ? 1 : 0
            } else {
                greeting = try await readPacket()
            }
            if greeting.first == 0xFF { throw ConnectionError.unreachable(MySQLPacket.error(greeting).message) }
            guard let handshake = MySQLHandshake(greeting) else { throw ConnectionError.protocolViolation("server greeting") }
            self.handshake = handshake
            capabilities = MySQLCapability.client(server: handshake.capabilities, hasDatabase: hasDatabase, tls: stream.isEncrypted)
            try await authenticate(handshake, encrypted: stream.isEncrypted)
            lock.withLock { threadID = handshake.threadID }
        } catch {
            stream.close()
            self.stream = nil
            throw error
        }
    }

    private func authenticate(_ handshake: MySQLHandshake, encrypted: Bool) async throws {
        let password = configuration.password ?? ""
        let canSendClearText = encrypted || configuration.isLocalSocket
        var plugin = handshake.plugin
        var salt = handshake.salt
        // With a default plugin Rowster does not know, offer its own: the server answers with a switch.
        if MySQLAuth.scramble(plugin: plugin, password: password, salt: salt) == nil { plugin = "caching_sha2_password" }
        try await reply(MySQLPacket.handshakeResponse(
            capabilities: capabilities, user: configuration.user,
            authResponse: MySQLAuth.scramble(plugin: plugin, password: password, salt: salt) ?? Data(),
            database: configuration.database, plugin: plugin))

        var awaitingPublicKey = false
        while true {
            let payload = try await readPacket()
            switch payload.first {
            case 0x00:
                status = MySQLPacket.ok(payload).status
                return
            case 0xFF:
                let error = MySQLPacket.error(payload)
                if error.code == "1045" || error.code == "1698" { throw ConnectionError.authenticationFailed(error.message) }
                throw ConnectionError.unreachable(error.message)
            case 0xFE:
                var reader = ByteReader(payload)
                reader.skip(1)
                plugin = reader.cString()
                salt = Data(reader.remaining().prefix(20))
                if let scramble = MySQLAuth.scramble(plugin: plugin, password: password, salt: salt) {
                    try await reply(scramble)
                } else if plugin == "mysql_clear_password", canSendClearText {
                    try await reply(Data(password.utf8) + [0])
                } else {
                    throw ConnectionError.unsupportedAuthentication(plugin)
                }
            case 0x01:
                if awaitingPublicKey {
                    awaitingPublicKey = false
                    let pem = String(decoding: payload.dropFirst(), as: UTF8.self)
                    guard let encrypted = MySQLAuth.encrypt(password: password, salt: salt, publicKeyPEM: pem) else {
                        throw ConnectionError.protocolViolation("server public key")
                    }
                    try await reply(encrypted)
                } else if payload.count == 2, payload[payload.startIndex + 1] == 0x04 {
                    // Full authentication: the password itself, protected by TLS or by the server's RSA key.
                    if canSendClearText {
                        try await reply(Data(password.utf8) + [0])
                    } else {
                        awaitingPublicKey = true
                        try await reply(Data([0x02]))
                    }
                }
            default:
                throw ConnectionError.protocolViolation("authentication packet")
            }
        }
    }

    public func close() async {
        if stream != nil { try? await command(Data([0x01])) }
        stream?.close()
        stream = nil
        hasOpenCursor = false
    }

    public var transactionState: TransactionState {
        get async { status & 0x0001 != 0 ? .inTransaction : .idle }
    }

    public var serverVersion: String? {
        get async {
            guard let version = handshake?.version else { return nil }
            guard let range = version.range(of: "-MariaDB") else { return "MySQL \(version)" }
            let number = version[..<range.lowerBound]
            return "MariaDB " + (number.hasPrefix("5.5.5-") ? number.dropFirst(6) : number)
        }
    }

    public func makeIntrospector() -> any SchemaIntrospecting { MySQLIntrospector(driver: self) }

    /// Runs `KILL QUERY` on a connection of its own.
    public func cancel() async {
        guard let id = lock.withLock({ threadID }) else { return }
        let killer = MySQLDriver(configuration: configuration, engine: engine)
        guard (try? await killer.connect()) != nil else { return }
        _ = try? await killer.run("KILL QUERY \(id)")
        await killer.close()
    }

    // MARK: - Statements

    public func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor {
        guard stream != nil else { throw ConnectionError.closed }
        guard !hasOpenCursor else { throw ConnectionError.busy }
        if parameters.isEmpty {
            try await command(Data([0x03]) + Data(sql.utf8))
            return try await readResult(binary: false, statement: nil)
        }

        try await command(Data([0x16]) + Data(sql.utf8))
        let prepared = try await readPacket()
        if prepared.first == 0xFF { throw MySQLPacket.error(prepared) }
        var reader = ByteReader(prepared)
        reader.skip(1)
        let statement = UInt32(truncatingIfNeeded: reader.uintLE(4))
        let columnCount = Int(reader.uintLE(2))
        let parameterCount = Int(reader.uintLE(2))
        try await skipDefinitions(parameterCount)
        try await skipDefinitions(columnCount)
        guard parameterCount == parameters.count else {
            try await closeStatement(statement)
            throw DatabaseError(
                message: "The statement has \(parameterCount) parameters but \(parameters.count) values were given", code: "PARAMETERS")
        }
        try await command(MySQLRow.execute(statement: statement, parameters: parameters))
        return try await readResult(binary: true, statement: statement)
    }

    private func skipDefinitions(_ count: Int) async throws {
        guard count > 0 else { return }
        for _ in 0..<count { _ = try await readPacket() }
        if !deprecateEOF { _ = try await readPacket() }
    }

    private func closeStatement(_ statement: UInt32?) async throws {
        guard let statement else { return }
        var payload = Data([0x19])
        payload.appendLE(UInt64(statement), bytes: 4)
        try await command(payload)
    }

    private func readResult(binary: Bool, statement: UInt32?) async throws -> MySQLCursor {
        let first = try await readPacket()
        switch first.first {
        case 0xFF:
            try await closeStatement(statement)
            throw MySQLPacket.error(first)
        case 0x00:
            let ok = MySQLPacket.ok(first)
            try await finish(status: ok.status, statement: statement)
            return MySQLCursor(driver: self, columns: [], binary: binary, statement: nil, affectedRows: ok.affectedRows)
        case 0xFB:
            // The server asks for a local file (LOAD DATA LOCAL). Rowster never sends one.
            try await reply(Data())
            _ = try await readPacket()
            throw DatabaseError(message: "LOAD DATA LOCAL INFILE is not supported", code: "LOCAL_INFILE")
        default:
            var reader = ByteReader(first)
            let count = Int(clamping: reader.lengthEncoded() ?? 0)
            var columns: [MySQLColumn] = []
            for _ in 0..<count { columns.append(MySQLColumn(try await readPacket())) }
            if !deprecateEOF { _ = try await readPacket() }
            hasOpenCursor = true
            return MySQLCursor(driver: self, columns: columns, binary: binary, statement: statement, affectedRows: nil)
        }
    }

    /// Called when a result is over: reads and drops the further results a procedure may return,
    /// then releases the prepared statement.
    fileprivate func finish(status: UInt16, statement: UInt32?) async throws {
        var current = status
        while current & 0x0008 != 0 {
            let first = try await readPacket()
            if first.first == 0xFF { throw MySQLPacket.error(first) }
            if first.first == 0x00 {
                current = MySQLPacket.ok(first).status
                continue
            }
            var reader = ByteReader(first)
            try await skipDefinitions(Int(clamping: reader.lengthEncoded() ?? 0))
            while true {
                let packet = try await readPacket()
                if packet.first == 0xFF { throw MySQLPacket.error(packet) }
                if MySQLPacket.isTerminator(packet, deprecateEOF: deprecateEOF) {
                    current = MySQLPacket.terminatorStatus(packet, deprecateEOF: deprecateEOF)
                    break
                }
            }
        }
        self.status = current
        hasOpenCursor = false
        try await closeStatement(statement)
    }

    fileprivate func fail(statement: UInt32?) async {
        hasOpenCursor = false
        try? await closeStatement(statement)
    }

    /// Absorbs a `KILL QUERY` that arrived after its statement ended, so it cannot hit the next one.
    fileprivate func absorbLateKill() async {
        _ = try? await run("DO 0")
    }
}

private final class MySQLCursor: ResultCursor, @unchecked Sendable {
    let columns: [ColumnInfo]
    private let definitions: [MySQLColumn]
    private let driver: MySQLDriver
    private let binary: Bool
    private let statement: UInt32?
    private var isFinished: Bool
    private var summary: CommandSummary

    init(driver: MySQLDriver, columns: [MySQLColumn], binary: Bool, statement: UInt32?, affectedRows: Int?) {
        self.driver = driver
        definitions = columns
        self.columns = columns.map(\.info)
        self.binary = binary
        self.statement = statement
        isFinished = columns.isEmpty
        summary = CommandSummary(rowsAffected: affectedRows)
    }

    /// Reads one packet of the result. Returns the row, or `nil` when the result ended.
    private func readRow() async throws -> Row? {
        let packet: Data
        do {
            packet = try await driver.readPacket()
        } catch {
            isFinished = true
            driver.hasOpenCursor = false
            throw error
        }
        if packet.first == 0xFF {
            isFinished = true
            await driver.fail(statement: statement)
            throw MySQLPacket.error(packet)
        }
        if MySQLPacket.isTerminator(packet, deprecateEOF: driver.deprecateEOF) {
            isFinished = true
            try await driver.finish(
                status: MySQLPacket.terminatorStatus(packet, deprecateEOF: driver.deprecateEOF), statement: statement)
            return nil
        }
        return binary ? MySQLRow.binary(packet, columns: definitions) : MySQLRow.text(packet, columns: definitions)
    }

    func next(maxRows: Int) async throws -> [Row]? {
        guard !isFinished else { return nil }
        var rows: [Row] = []
        while rows.count < maxRows, let row = try await readRow() { rows.append(row) }
        return rows.isEmpty && isFinished ? nil : rows
    }

    /// The protocol has no way to stop a result: what was not read must be read, or the query killed.
    /// A short remainder is simply read; a long one is cut with `KILL QUERY`.
    func close() async throws -> CommandSummary {
        guard !isFinished else { return summary }
        var dropped = 0
        while dropped < 2000 {
            guard try await readRow() != nil else { return summary }
            dropped += 1
        }
        await driver.cancel()
        do {
            while try await readRow() != nil {}
        } catch let error as DatabaseError where error.isCancellation {
            // The expected end of a killed query.
        }
        await driver.absorbLateKill()
        return summary
    }
}
