import XCTest
@testable import RowsterCore

final class ViewStateStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rowster-state-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFileStoreRoundTripAcrossInstances() {
        let connection = UUID()
        let orders = TableRef(schema: "shop", name: "orders")
        let state = TableViewState(
            sort: [SortTerm(column: "status", ascending: false), SortTerm(column: "id")], columnWidths: ["status": 140.5])

        let store = FileViewStateStore(directory: directory)
        XCTAssertEqual(store.state(connection: connection, table: orders), TableViewState())
        store.save(state, connection: connection, table: orders)
        XCTAssertEqual(store.state(connection: connection, table: orders), state)

        let reopened = FileViewStateStore(directory: directory)
        XCTAssertEqual(reopened.state(connection: connection, table: orders), state)
        XCTAssertEqual(reopened.state(connection: connection, table: TableRef(name: "orders")), TableViewState())
        XCTAssertEqual(reopened.state(connection: UUID(), table: orders), TableViewState())
    }

    func testMemoryStore() {
        let store = MemoryViewStateStore()
        let connection = UUID()
        let table = TableRef(name: "t")
        store.save(TableViewState(sort: [SortTerm(column: "a")]), connection: connection, table: table)
        XCTAssertEqual(store.state(connection: connection, table: table).sort, [SortTerm(column: "a")])
        XCTAssertEqual(store.state(connection: UUID(), table: table), TableViewState())
    }
}
