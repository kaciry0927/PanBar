import SwiftUI

/// 行业板块 Tab:涨幅榜(前 5)+ 跌幅榜(前 5)。
/// 打开时默认展开涨幅榜,跌幅榜折叠;点击表头切换。
struct SectorsTab: View {
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences
    @EnvironmentObject var intraday: IntradayStore

    /// 涨幅榜默认展开,跌幅榜默认收起。
    @State private var showGainers = true
    @State private var showLosers = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if refresher.sectorGainers.isEmpty && refresher.sectorLosers.isEmpty {
                    emptyState
                } else {
                    SectionHeader(
                        title: L("sectors.gainers", comment: ""),
                        isExpanded: $showGainers,
                        tint: SemanticColors.up(scheme: prefs.colorScheme)
                    )
                    if showGainers {
                        rows(refresher.sectorGainers)
                    }

                    SectionHeader(
                        title: L("sectors.losers", comment: ""),
                        isExpanded: $showLosers,
                        tint: SemanticColors.down(scheme: prefs.colorScheme)
                    )
                    if showLosers {
                        rows(refresher.sectorLosers)
                    }
                }
            }
        }
        .thinScrollbar()
        .frame(maxHeight: 320)
        .onAppear {
            // 每次切回本 Tab 都复位为默认:涨幅榜展开、跌幅榜收起。
            // 不能只依赖 @State 的初始值 —— switch 分支切换时 SwiftUI
            // 可能复用视图身份、保留上次的折叠状态,故在出现时显式重置。
            showGainers = true
            showLosers = false
            // 分时展开状态由 IntradayStore 全局单持,同样要收起,否则
            // 打开过某只板块的分时后,来回切 Tab 会残留展开。
            intraday.collapseExpanded()
        }
        .task { refresher.refreshSectorsNow() }
    }

    private func rows(_ boards: [SectorBoard]) -> some View {
        ForEach(boards) { board in
            Button {
                toggleIntraday(board)
            } label: {
                SectorRow(board: board, scheme: prefs.colorScheme, isExpanded: intraday.expandedKey == board.code)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if intraday.expandedKey == board.code {
                IntradaySectionView(target: .sector(board), key: board.code, scheme: prefs.colorScheme)
            }
            if board.id != boards.last?.id {
                Divider().opacity(0.4)
            }
        }
    }

    /// 单击行:展开/收起当日分时(手风琴,状态由 IntradayStore 全局单持)。
    private func toggleIntraday(_ board: SectorBoard) {
        withAnimation(.easeInOut(duration: 0.2)) {
            intraday.toggle(target: .sector(board))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(L("sectors.empty", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 可折叠的分组表头(涨幅榜 / 跌幅榜)。
private struct SectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    let tint: Color

    var body: some View {
        Button {
            // 原子切换:不套 withAnimation,popover 高度交给 NSPopover.sizingOptions 自动跟随
            // (见 .workbuddy/memory 里 popover 高度动画只能有一个动画源的教训)。
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SectorRow: View {
    let board: SectorBoard
    let scheme: TickerColorScheme
    /// 该行分时区是否展开(行尾 chevron 提示)。
    let isExpanded: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(board.name)
                    .font(.system(size: 13, weight: .semibold))
                leadingLine
            }
            Spacer()
            pctPill
            expandChevron
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var expandChevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 10)
    }

    private var leadingLine: some View {
        HStack(spacing: 4) {
            Text(L("sectors.leading", comment: ""))
            if let stock = board.leadingStock, !stock.isEmpty {
                Text(stock)
                    .foregroundColor(.primary)
            }
            if let pct = board.leadingStockChangePct {
                Text(String(format: "%+.2f%%", pct))
                    .foregroundColor(SemanticColors.directional(pct, scheme: scheme))
            }
            Text("\(board.upCount)/\(board.downCount)")
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private var pctPill: some View {
        Text(String(format: "%+.2f%%", board.changePct))
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundColor(SemanticColors.directional(board.changePct, scheme: scheme))
            .background(SemanticColors.directional(board.changePct, scheme: scheme).opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
