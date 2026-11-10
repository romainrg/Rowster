import RowsterCore
import SwiftUI

/// The tabs of a work window, tinted with the color of the connection.
struct TabBarView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabChip(
                            tab: tab, isSelected: tab.id == model.selectedTabID, tint: model.profile.effectiveColor.color,
                            select: { model.selectedTabID = tab.id },
                            keep: { tab.isPreview = false },
                            close: { model.closeTab(tab.id) })
                    }
                }
                .padding(.horizontal, 8)
            }
            Button {
                model.newQueryTab()
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("New query tab"))
            .accessibilityLabel(Text("New query tab"))
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(wash)
    }

    /// The tab bar, washed with the connection color like the toolbar above it.
    private var wash: LinearGradient {
        let tint = model.profile.effectiveColor.color
        let strength = model.profile.label == .none ? 0.06 : 0.14
        return LinearGradient(
            colors: [tint.opacity(strength), tint.opacity(strength * 0.35)], startPoint: .leading, endPoint: .trailing)
    }
}

private struct TabChip: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let tint: Color
    let select: () -> Void
    let keep: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.symbol).font(.system(size: 10.5)).foregroundStyle(isSelected ? tint : .secondary)
            Text(verbatim: tab.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .italic(tab.isPreview)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isSelected ? 1 : 0)
            .accessibilityLabel(Text("Close \(tab.title)"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.cardFill : (isHovering ? Theme.softFill.opacity(0.6) : .clear))
                .shadow(color: isSelected ? Theme.cardShadow : .clear, radius: 4, y: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2, perform: keep)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
