import AppKit
import RowsterCore

/// Sample connections and data for demo mode, previews and screenshots. Nothing here touches the
/// network, the disk or the Keychain.
enum DemoData {
    static let shopGroup = ConnectionGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Shop")
    static let analyticsGroup = ConnectionGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Analytics")

    static let local = profile(1, "Shop", .sqlite, .local, group: shopGroup) { $0.filePath = "~/Projects/shop/dev.sqlite" }
    static let staging = profile(2, "Shop staging", .postgres, .staging, group: shopGroup) {
        $0.host = "staging-db.shop.example"
        $0.user = "app"
        $0.database = "shop"
        $0.tlsMode = .required
    }
    static let production = profile(3, "Shop production", .postgres, .production, group: shopGroup) {
        $0.host = "db.shop.example"
        $0.user = "readonly"
        $0.database = "shop"
        $0.tlsMode = .verifyIdentity
        $0.ssh.isEnabled = true
        $0.ssh.host = "bastion"
    }
    static let events = profile(4, "Events", .mysql, .development, group: analyticsGroup) {
        $0.host = "127.0.0.1"
        $0.user = "root"
        $0.database = "events"
    }
    static let warehouse = profile(5, "Warehouse", .mariadb, .none, group: analyticsGroup) {
        $0.host = "warehouse.internal.example"
        $0.port = 3307
        $0.user = "reports"
        $0.database = "dwh"
    }
    static let notes = profile(6, "Notes", .sqlite, .none, group: nil) { $0.filePath = "~/Documents/notes.db" }

    static var library: ConnectionLibrary {
        ConnectionLibrary(
            groups: [shopGroup, analyticsGroup], connections: [local, staging, production, events, warehouse, notes])
    }

    private static func profile(
        _ number: Int, _ name: String, _ engine: Engine, _ label: EnvironmentLabel, group: ConnectionGroup?,
        configure: (inout ConnectionProfile) -> Void
    ) -> ConnectionProfile {
        var profile = ConnectionProfile(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02X", number))!, name: name, engine: engine)
        profile.label = label
        profile.groupID = group?.id
        configure(&profile)
        return profile
    }
}

/// Serves every demo connection from an in-memory SQLite database shared by the connections of one profile.
struct DemoDriverProvider: DriverProviding {
    func makeDriver(
        for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool
    ) throws -> any DatabaseDriver {
        DemoDriver(engine: profile.engine, name: "rowster-demo-\(profile.id.uuidString)", readOnly: readOnly)
    }
}

/// A SQLite driver that fills its database with the sample data on first connection and reports the
/// version of the engine it stands for.
final class DemoDriver: DatabaseDriver, @unchecked Sendable {
    private let inner: SQLiteDriver
    private let engine: Engine
    private let readOnly: Bool

    init(engine: Engine, name: String, readOnly: Bool) {
        self.engine = engine
        self.readOnly = readOnly
        inner = SQLiteDriver(configuration: .sharedMemory(name: name))
    }

    var dialect: any SQLDialect { inner.dialect }

    func connect() async throws {
        try await inner.connect()
        let tables = try await inner.query("SELECT count(*) FROM sqlite_master")
        if tables.rows.first?.first == .integer(0) {
            try await DemoDatabase.seed(inner)
        }
        if readOnly { try await inner.setReadOnly(true) }
    }

    func close() async { await inner.close() }

    func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor {
        try await inner.execute(sql, parameters: parameters)
    }

    func cancel() async { await inner.cancel() }

    var transactionState: TransactionState {
        get async { await inner.transactionState }
    }

    var serverVersion: String? {
        get async {
            switch engine {
            case .postgres: return "PostgreSQL 17.2"
            case .mysql: return "MySQL 8.4.3"
            case .mariadb: return "MariaDB 11.4.4"
            case .sqlite: return await inner.serverVersion.map { "SQLite \($0)" }
            }
        }
    }

    func setReadOnly(_ readOnly: Bool) async throws { try await inner.setReadOnly(readOnly) }
    func makeIntrospector() -> any SchemaIntrospecting { inner.makeIntrospector() }
}

/// A small shop: customers, products, orders and their items, an audit log and a view.
enum DemoDatabase {
    static let schema = [
        """
        CREATE TABLE customers (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          email TEXT NOT NULL UNIQUE,
          country TEXT NOT NULL,
          vip BOOLEAN NOT NULL DEFAULT 0,
          created_at DATETIME NOT NULL
        )
        """,
        """
        CREATE TABLE products (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          price DECIMAL(10,2) NOT NULL,
          stock INTEGER NOT NULL DEFAULT 0,
          attributes JSON,
          photo BLOB
        )
        """,
        """
        CREATE TABLE orders (
          id INTEGER PRIMARY KEY,
          customer_id INTEGER NOT NULL REFERENCES customers (id),
          status TEXT NOT NULL DEFAULT 'pending',
          total DECIMAL(10,2) NOT NULL,
          note TEXT,
          placed_at DATETIME NOT NULL
        )
        """,
        "CREATE INDEX orders_customer ON orders (customer_id)",
        "CREATE INDEX orders_status ON orders (status, placed_at)",
        """
        CREATE TABLE order_items (
          order_id INTEGER NOT NULL REFERENCES orders (id),
          product_id INTEGER NOT NULL REFERENCES products (id),
          quantity INTEGER NOT NULL DEFAULT 1,
          unit_price DECIMAL(10,2) NOT NULL,
          PRIMARY KEY (order_id, product_id)
        ) WITHOUT ROWID
        """,
        "CREATE TABLE audit_log (happened_at DATETIME NOT NULL, actor TEXT, action TEXT NOT NULL)",
        """
        CREATE VIEW order_totals AS
        SELECT c.id AS customer_id, c.name, count(o.id) AS orders, round(sum(o.total), 2) AS spent
        FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
        GROUP BY c.id
        """
    ]

    private static let customers: [(String, String)] = [
        ("Ada Moreau", "FR"), ("Liam O'Connor", "IE"), ("Sofia Rossi", "IT"), ("Noah Becker", "DE"),
        ("Inès Lambert", "FR"), ("Mateo García", "ES"), ("Emma Nilsson", "SE"), ("Lucas Martin", "FR"),
        ("Olivia Smith", "GB"), ("Hugo Dubois", "BE"), ("Mia Jansen", "NL"), ("Elias Novak", "CZ"),
        ("Chloé Petit", "FR"), ("Leo Fischer", "AT"), ("Zoé Renard", "CH"), ("Oscar Lindqvist", "SE"),
        ("Jade Fontaine", "FR"), ("Arthur Keller", "DE"), ("Nina Kowalska", "PL"), ("Théo Girard", "FR"),
        ("Alice Moretti", "IT"), ("Samuel Costa", "PT"), ("Léa Marchand", "FR"), ("Felix Braun", "DE")
    ]

    private static let products: [(String, Double, String, NSColor)] = [
        ("Field notebook", 12.5, #"{"color": "ochre", "pages": 96, "ruled": true}"#, .systemOrange),
        ("Fountain pen", 48, #"{"nib": "F", "colors": ["navy", "forest"], "refillable": true}"#, .systemBlue),
        ("Ink bottle 50 ml", 14.9, #"{"color": "midnight", "volume_ml": 50}"#, .systemIndigo),
        ("Desk lamp", 89, #"{"watts": 9, "dimmable": true, "finish": {"base": "oak", "shade": "linen"}}"#, .systemYellow),
        ("Canvas tote", 22, #"{"sizes": ["S", "L"], "organic": true}"#, .systemGreen),
        ("Ceramic mug", 18.5, #"{"capacity_ml": 350, "dishwasher": true}"#, .systemTeal),
        ("Wool blanket", 129, #"{"size": "140x200", "origin": "PT"}"#, .systemRed),
        ("Brass ruler", 27.5, #"{"length_cm": 30}"#, .systemBrown),
        ("Pencil set", 9.9, #"{"count": 12, "grades": ["HB", "2B", "4B"]}"#, .systemGray),
        ("Leather sleeve", 64, #"{"fits": ["13\"", "14\""], "color": "tan"}"#, .systemPink),
        ("Postcards", 6.5, "{\"count\": 10, \"artist\": null}", .systemPurple),
        ("Gift card", 50, #"{"digital": true}"#, .systemMint)
    ]

    private static let statuses = ["delivered", "delivered", "shipped", "paid", "pending", "delivered", "cancelled", "failed"]
    private static let notes: [String?] = [nil, nil, "Gift wrap", nil, "Leave with the neighbour", nil, nil, "Call before delivery"]

    static func seed(_ driver: any DatabaseDriver) async throws {
        try await driver.run("BEGIN")
        for statement in schema { try await driver.run(statement) }

        for (index, customer) in customers.enumerated() {
            let email = customer.0.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .replacingOccurrences(of: " ", with: ".").replacingOccurrences(of: "'", with: "") + "@example.com"
            try await driver.run(
                "INSERT INTO customers (id, name, email, country, vip, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                parameters: [
                    .integer(Int64(index + 1)), .text(customer.0), .text(email), .text(customer.1),
                    .integer(index % 5 == 0 ? 1 : 0), .text(date(daysAgo: 400 - index * 13, minute: index * 37))
                ])
        }

        for (index, product) in products.enumerated() {
            try await driver.run(
                "INSERT INTO products (id, name, price, stock, attributes, photo) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                parameters: [
                    .integer(Int64(index + 1)), .text(product.0), .double(product.1), .integer(Int64((index * 17) % 60)),
                    .text(product.2), index == 10 ? .null : .bytes(photo(color: product.3, letter: String(product.0.prefix(1))))
                ])
        }

        for order in 1...420 {
            let items = (0..<(1 + order % 3)).map { offset in (product: (order * 5 + offset * 7) % products.count, quantity: 1 + (order + offset) % 3) }
            var seen = Set<Int>()
            let unique = items.filter { seen.insert($0.product).inserted }
            let total = unique.reduce(0.0) { $0 + products[$1.product].1 * Double($1.quantity) }
            try await driver.run(
                "INSERT INTO orders (id, customer_id, status, total, note, placed_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                parameters: [
                    .integer(Int64(order)), .integer(Int64((order * 7) % customers.count + 1)),
                    .text(statuses[order % statuses.count]), .double((total * 100).rounded() / 100),
                    notes[order % notes.count].map(SQLValue.text) ?? .null, .text(date(daysAgo: (420 - order) / 2, minute: order * 53))
                ])
            for item in unique {
                try await driver.run(
                    "INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (?1, ?2, ?3, ?4)",
                    parameters: [
                        .integer(Int64(order)), .integer(Int64(item.product + 1)), .integer(Int64(item.quantity)),
                        .double(products[item.product].1)
                    ])
            }
        }

        for (index, action) in ["login", "export orders", "refund order 118", "login", "update product 4"].enumerated() {
            try await driver.run(
                "INSERT INTO audit_log (happened_at, actor, action) VALUES (?1, ?2, ?3)",
                parameters: [.text(date(daysAgo: index, minute: index * 91)), index == 3 ? .null : .text("ada"), .text(action)])
        }
        try await driver.run("COMMIT")
    }

    /// A fixed reference date keeps screenshots identical from one day to the next.
    private static func date(daysAgo: Int, minute: Int) -> String {
        var components = DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 11, day: 2, hour: 9)
        components.day! -= daysAgo
        components.minute = minute % 600
        let date = Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func photo(color: NSColor, letter: String) -> Data {
        let size = 96
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(starting: color, ending: color.blended(withFraction: 0.45, of: .black) ?? color)?
            .draw(in: NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20), angle: -60)
        let text = NSAttributedString(
            string: letter,
            attributes: [.font: NSFont.systemFont(ofSize: 52, weight: .bold), .foregroundColor: NSColor.white])
        let textSize = text.size()
        text.draw(at: NSPoint(x: (CGFloat(size) - textSize.width) / 2, y: (CGFloat(size) - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
