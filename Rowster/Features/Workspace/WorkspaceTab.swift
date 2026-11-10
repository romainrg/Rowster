import RowsterCore
import SwiftUI

/// One tab of a work window: a table or a query.
@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    enum Content {
        case table(TableTabModel)
        case query(QueryTabModel)
    }

    let id = UUID()
    let content: Content
    /// A preview tab was opened by a single click and is replaced by the next one.
    var isPreview: Bool

    init(content: Content, isPreview: Bool = false) {
        self.content = content
        self.isPreview = isPreview
    }

    var title: String {
        switch content {
        case .table(let model): return model.ref.name
        case .query(let model): return model.title
        }
    }

    var symbol: String {
        switch content {
        case .table(let model): return model.kind == .view ? "eye" : "tablecells"
        case .query: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var table: TableTabModel? {
        if case .table(let model) = content { return model }
        return nil
    }
}

/// A SQL editor tab.
@MainActor
@Observable
final class QueryTabModel {
    let number: Int
    var text = ""

    init(number: Int) { self.number = number }

    var title: String { String(localized: "Query \(number)") }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
