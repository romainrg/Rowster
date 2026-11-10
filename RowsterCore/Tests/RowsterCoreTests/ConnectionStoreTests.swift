import XCTest
@testable import RowsterCore

final class ConnectionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rowster-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleLibrary() -> ConnectionLibrary {
        let group = ConnectionGroup(name: "Shop")
        var production = ConnectionProfile(name: "Shop production", engine: .postgres)
        production.label = .production
        production.color = .green
        production.groupID = group.id
        production.host = "db.example.com"
        production.user = "app"
        production.database = "shop"
        production.tlsMode = .verifyIdentity
        production.ssh.isEnabled = true
        production.ssh.host = "bastion"
        production.bootstrapSQL = "SET search_path = shop"
        var local = ConnectionProfile(name: "Notes", engine: .sqlite)
        local.filePath = "/tmp/notes.sqlite"
        return ConnectionLibrary(groups: [group], connections: [production, local])
    }

    func testRoundTrip() throws {
        let store = FileConnectionStore(url: directory.appendingPathComponent("nested/connections.json"))
        XCTAssertEqual(try store.load(), ConnectionLibrary())
        let library = sampleLibrary()
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testTheStoredFormHasNoSecretField() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: FileConnectionStore.encode(sampleLibrary())) as? [String: Any])
        let connections = try XCTUnwrap(json["connections"] as? [[String: Any]])
        XCTAssertEqual(connections.count, 2)
        for connection in connections {
            for key in connection.keys {
                let lowered = key.lowercased()
                XCTAssertFalse(lowered.contains("password") && key != "passwordStorage", key)
                XCTAssertFalse(lowered.contains("secret") || lowered.contains("passphrase") || lowered.contains("token"), key)
            }
            XCTAssertTrue(["keychain", "askEveryTime"].contains(connection["passwordStorage"] as? String))
        }
    }

    func testProductionIsAlwaysRedAndReadOnly() {
        var profile = ConnectionProfile(name: "p")
        profile.label = .production
        profile.color = .green
        profile.opensReadOnly = false
        XCTAssertEqual(profile.effectiveColor, .red)
        XCTAssertTrue(profile.isReadOnlyOnOpen)
        profile.label = .staging
        XCTAssertEqual(profile.effectiveColor, .green)
        XCTAssertFalse(profile.isReadOnlyOnOpen)
        profile.color = nil
        XCTAssertEqual(profile.effectiveColor, .orange)
        profile.opensReadOnly = true
        XCTAssertTrue(profile.isReadOnlyOnOpen)
    }

    func testSummary() {
        var profile = ConnectionProfile(engine: .postgres)
        profile.host = "db.example.com"
        profile.database = "shop"
        XCTAssertEqual(profile.summary, "db.example.com/shop")
        profile.port = 6543
        XCTAssertEqual(profile.summary, "db.example.com:6543/shop")
        profile.port = 5432
        XCTAssertEqual(profile.summary, "db.example.com/shop")
        profile.ssh.isEnabled = true
        profile.ssh.host = "bastion"
        XCTAssertEqual(profile.summary, "db.example.com/shop ⇢ bastion")
        XCTAssertEqual(profile.displayName, profile.summary)
        profile.name = "Shop"
        XCTAssertEqual(profile.displayName, "Shop")
    }

    func testSearch() {
        let library = sampleLibrary()
        XCTAssertEqual(library.search("").count, 2)
        XCTAssertEqual(library.search("  shop PROD ").map(\.name), ["Shop production"])
        XCTAssertEqual(library.search("sqlite").map(\.name), ["Notes"])
        XCTAssertEqual(library.search("example.com app").map(\.name), ["Shop production"])
        XCTAssertTrue(library.search("nothing").isEmpty)
    }

    func testMemoryStores() throws {
        let store = MemoryConnectionStore()
        try store.save(sampleLibrary())
        XCTAssertEqual(try store.load().connections.count, 2)

        let secrets = MemorySecretStore()
        let id = UUID()
        XCTAssertNil(try secrets.password(for: id))
        try secrets.setPassword("s3cret", for: id)
        XCTAssertEqual(try secrets.password(for: id), "s3cret")
        try secrets.deletePassword(for: id)
        XCTAssertNil(try secrets.password(for: id))
    }

    func testLiveProviderOpensSQLiteAndRefusesWhatIsNotBuiltYet() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("t.sqlite").path
        let writer = SQLiteDriver(configuration: SQLiteConfiguration(path: path, createIfMissing: true))
        try await writer.connect()
        try await writer.run("CREATE TABLE t (a)")
        await writer.close()

        var profile = ConnectionProfile(name: "t", engine: .sqlite)
        profile.filePath = path
        let version = try await LiveDriverProvider().test(profile, password: nil)
        XCTAssertNotNil(version)

        profile.filePath = ""
        XCTAssertThrowsError(try LiveDriverProvider().makeDriver(for: profile, password: nil, database: nil, readOnly: false)) {
            XCTAssertEqual($0 as? DriverProviderError, .missingFilePath)
        }
    }
}
