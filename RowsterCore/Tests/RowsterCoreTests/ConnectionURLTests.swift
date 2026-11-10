import XCTest
@testable import RowsterCore

final class ConnectionURLTests: XCTestCase {
    func testPostgres() throws {
        let parsed = try XCTUnwrap(ConnectionURL.parse("  postgres://app:s3cret@db.example.com:6543/shop?sslmode=require \n"))
        XCTAssertEqual(parsed.engine, .postgres)
        XCTAssertEqual(parsed.host, "db.example.com")
        XCTAssertEqual(parsed.port, 6543)
        XCTAssertEqual(parsed.user, "app")
        XCTAssertEqual(parsed.password, "s3cret")
        XCTAssertEqual(parsed.database, "shop")
        XCTAssertEqual(parsed.tlsMode, .required)
        XCTAssertTrue(parsed.unknownParameters.isEmpty)
    }

    func testSchemesAndDefaults() throws {
        XCTAssertEqual(ConnectionURL.parse("postgresql://localhost/db")?.engine, .postgres)
        XCTAssertEqual(ConnectionURL.parse("MYSQL://root@localhost")?.engine, .mysql)
        XCTAssertEqual(ConnectionURL.parse("mariadb://localhost/db")?.engine, .mariadb)
        let bare = try XCTUnwrap(ConnectionURL.parse("mysql://localhost"))
        XCTAssertNil(bare.port)
        XCTAssertNil(bare.password)
        XCTAssertNil(bare.tlsMode)
        XCTAssertEqual(bare.user, "")
        XCTAssertEqual(bare.database, "")
    }

    func testPercentEncodedCredentials() throws {
        let parsed = try XCTUnwrap(ConnectionURL.parse("postgres://us%40er:p%40ss%3Aw%2Ford%20x@host/my%20db"))
        XCTAssertEqual(parsed.user, "us@er")
        XCTAssertEqual(parsed.password, "p@ss:w/ord x")
        XCTAssertEqual(parsed.database, "my db")
    }

    func testTLSModes() {
        let cases: [(String, TLSMode)] = [
            ("sslmode=disable", .disabled), ("sslmode=prefer", .preferred), ("sslmode=verify-ca", .verifyCA),
            ("sslmode=verify-full", .verifyIdentity), ("ssl-mode=REQUIRED", .required), ("ssl-mode=VERIFY_IDENTITY", .verifyIdentity),
            ("ssl=true", .required), ("ssl=false", .disabled)
        ]
        for (query, mode) in cases {
            XCTAssertEqual(ConnectionURL.parse("postgres://h/d?\(query)")?.tlsMode, mode, query)
        }
    }

    func testUnknownParametersAreReported() throws {
        let parsed = try XCTUnwrap(ConnectionURL.parse("postgres://h/d?sslmode=bogus&application_name=x&connect_timeout=5"))
        XCTAssertNil(parsed.tlsMode)
        XCTAssertEqual(parsed.unknownParameters, ["sslmode", "application_name", "connect_timeout"])
    }

    func testIPv6Host() {
        XCTAssertEqual(ConnectionURL.parse("postgres://user@[::1]:5433/db")?.host, "::1")
    }

    func testSQLite() {
        XCTAssertEqual(ConnectionURL.parse("sqlite:///Users/me/My%20Data/app.db")?.filePath, "/Users/me/My Data/app.db")
        XCTAssertEqual(ConnectionURL.parse("sqlite:relative.db")?.filePath, "relative.db")
        XCTAssertNil(ConnectionURL.parse("sqlite://"))
    }

    func testNotAConnectionURL() {
        for text in ["", "hello", "https://example.com/db", "postgres://", "/Users/me/app.db", "postgres:"] {
            XCTAssertNil(ConnectionURL.parse(text), text)
        }
    }

    func testApplyKeepsTheRestOfTheProfile() throws {
        var profile = ConnectionProfile(name: "Kept", engine: .mysql)
        profile.label = .staging
        profile.tlsMode = .verifyCA
        try XCTUnwrap(ConnectionURL.parse("postgres://app:pw@h:1/d")).apply(to: &profile)
        XCTAssertEqual(profile.name, "Kept")
        XCTAssertEqual(profile.label, .staging)
        XCTAssertEqual(profile.engine, .postgres)
        XCTAssertEqual(profile.host, "h")
        XCTAssertEqual(profile.port, 1)
        XCTAssertEqual(profile.user, "app")
        XCTAssertEqual(profile.database, "d")
        XCTAssertEqual(profile.tlsMode, .verifyCA)
    }

    func testGeneratedURLNeverHasAPassword() throws {
        var profile = ConnectionProfile(name: "x", engine: .postgres)
        profile.host = "db.example.com"
        profile.port = 6543
        profile.user = "us@er"
        profile.database = "shop"
        profile.tlsMode = .verifyIdentity
        let url = ConnectionURL.string(for: profile)
        XCTAssertEqual(url, "postgres://us%40er@db.example.com:6543/shop?sslmode=verify-full")
        let back = try XCTUnwrap(ConnectionURL.parse(url))
        XCTAssertNil(back.password)
        XCTAssertEqual(back.user, "us@er")
        XCTAssertEqual(back.tlsMode, .verifyIdentity)

        var sqlite = ConnectionProfile(name: "s", engine: .sqlite)
        sqlite.filePath = "/tmp/a.db"
        XCTAssertEqual(ConnectionURL.string(for: sqlite), "sqlite:///tmp/a.db")
    }
}
