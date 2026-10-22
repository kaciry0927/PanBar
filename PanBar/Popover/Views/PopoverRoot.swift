import SwiftUI
import UniformTypeIdentifiers

struct PopoverRoot: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences
    @Environment(\.container) private var container

    /// 每 30 秒强制重算市场状态(开市/午休/休市切换);用 timer trigger 让 @State 变化触发重渲染
    @State private var statusTick: Date = Date()
    private let statusTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            if summaryCardsVisible {
                SummaryCards(snapshot: refresher.snapshot)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            if !visibleTabs.isEmpty {
                tabs
                Divider()
                content
                    // 动态高度:不再用 maxHeight: .infinity 撑满固定 frame,整个 popover
                    // 的高度由内容自然高度决定(宽度仍由 PopoverController 注入的 frame 固定)。
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            Divider()
            footer
        }
        .onReceive(statusTimer) { statusTick = $0 }
        .onAppear { correctCurrentTabIfHidden() }
        .onChange(of: prefs.popoverHiddenTabs) { _ in correctCurrentTabIfHidden() }
    }

    /// 三张汇总卡片全部关闭时,把整块区域(含留白)收起。
    private var summaryCardsVisible: Bool {
        prefs.popoverShowTodayPnL || prefs.popoverShowAllTimePnL || prefs.popoverShowTotalAssets
    }

    /// 导航栏里实际显示的 tab(按 tabOrder 排序,过滤掉被隐藏的)。
    /// 空 = 全部隐藏,此时 tab 区与 content 区一并收起,popover 退化成纯状态面板。
    private var visibleTabs: [PopoverViewModel.Tab] {
        vm.tabOrder.filter { !prefs.popoverHiddenTabs.contains($0.rawValue) }
    }

    /// 当前选中的 tab 被隐藏时,自动切到第一个可见 tab。
    /// 全隐藏时 visibleTabs 为空,content 不渲染,currentTab 保持不变即可。
    private func correctCurrentTabIfHidden() {
        guard prefs.popoverHiddenTabs.contains(vm.currentTab.rawValue),
              let first = visibleTabs.first else { return }
        vm.currentTab = first
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                Text("P")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("PanBar")
                        .font(.system(size: 14, weight: .semibold))
                    if let updated = refresher.lastUpdated, Date().timeIntervalSince(updated) < 15 {
                        Text("Live")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                marketStatusRow
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help(L("menu.settings", comment: ""))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// 三个市场的实时状态:绿点=开盘 / 黄=午休 / 灰=休市
    /// 末尾的 ? 图标:hover 出 tooltip 显示完整时段,点击跳设置 → 市场
    @ViewBuilder
    private var marketStatusRow: some View {
        if let clock = container?.clock {
            HStack(spacing: 8) {
                ForEach(Market.allCases, id: \.self) { market in
                    let status = clock.status(market, at: statusTick)
                    HStack(spacing: 3) {
                        Circle()
                            .fill(statusColor(status))
                            .frame(width: 5, height: 5)
                        Text(marketShortName(market))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(statusLabel(status))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                Button(action: openMarketSettings) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(marketHoursTooltip)
            }
        }
    }

    private var marketHoursTooltip: String {
        // 一行一个市场,SwiftUI tooltip 支持多行 \n
        return [
            L("market.hours.a", comment: ""),
            L("market.hours.hk", comment: ""),
            L("market.hours.us", comment: ""),
            "",
            L("market.tooltip.openSettings", comment: "")
        ].joined(separator: "\n")
    }

    private func openMarketSettings() {
        SettingsWindowController.preferredPane = .markets
        SettingsWindowController.shared.show()
    }

    private func marketShortName(_ m: Market) -> String {
        switch m {
        case .a: return "A"
        case .hk: return "HK"
        case .us: return "US"
        }
    }

    private func statusColor(_ s: MarketStatus) -> Color {
        switch s {
        case .open: return .green
        case .lunchBreak: return .yellow
        case .closed: return .secondary.opacity(0.5)
        }
    }

    private func statusLabel(_ s: MarketStatus) -> String {
        switch s {
        case .open:       return L("market.status.open", comment: "")
        case .lunchBreak: return L("market.status.lunch", comment: "")
        case .closed:     return L("market.status.closed", comment: "")
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(visibleTabs) { tab in
                Button(action: { vm.currentTab = tab }) {
                    Text(tab.title)
                        .font(.system(size: 11, weight: vm.currentTab == tab ? .semibold : .regular))
                        .foregroundColor(vm.currentTab == tab ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(vm.currentTab == tab ? Color.primary.opacity(0.08) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .opacity(vm.draggingTab == tab ? 0.4 : 1)
                .onDrag {
                    vm.dragDidEnter(tab)
                    return NSItemProvider(object: tab.rawValue as NSString)
                }
                .onDrop(of: [UTType.text], delegate: TabDropDelegate(
                    item: tab,
                    vm: vm
                ))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.currentTab {
        case .holdings:  HoldingsTab()
        case .watchlist: WatchlistTab()
        case .indices:   IndicesTab()
        case .sectors:   SectorsTab()
        case .alerts:    AlertsTab()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: { refresher.refreshNow() }) {
                HStack(spacing: 5) {
                    if refresher.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: footerIcon)
                            .foregroundColor(footerIconColor)
                    }
                    Text(footerStatus)
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(refresher.isRefreshing)

            Spacer()
            Button(action: openGitHub) {
                Image("GitHubMark")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("footer.github.tooltip", comment: ""))

            Button(action: openDonate) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.pink.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(L("footer.donate.tooltip", comment: ""))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func openGitHub() {
        if let url = URL(string: "https://github.com/TNT-Likely/PanBar") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openDonate() {
        let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let urlString = isChinese
            ? "https://github.com/TNT-Likely/BeeCount/blob/main/docs/donate/README_ZH.md"
            : "https://github.com/TNT-Likely/BeeCount/blob/main/docs/donate/README_EN.md"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private var footerStatus: String {
        if refresher.isOffline {
            return L("footer.offline", comment: "")
        }
        if hasQuoteError {
            return L("footer.quoteFailed", comment: "")
        }
        // 还没拿到任何 fresh 数据,但有磁盘 seed 进来的旧数据
        if refresher.snapshotIsFromCache {
            return L("footer.cached", comment: "")
        }
        if refresher.isRefreshing && refresher.lastUpdated == nil {
            return L("footer.refreshing", comment: "")
        }
        if let t = refresher.lastUpdated {
            let interval = Int(Date().timeIntervalSince(t))
            return String(format: L("footer.updated", comment: ""), interval)
        }
        return L("footer.loading", comment: "")
    }

    /// 文字统一用 .secondary 灰色保证两个模式下都清晰可读,状态用图标颜色区分:
    ///   - 离线:橙色 wifi.slash
    ///   - 行情失败:橙色感叹号
    ///   - cached:橙色 clock(让用户知道在看的不是最新值,但不刺眼)
    ///   - 正常:灰色刷新箭头
    private var footerIcon: String {
        if refresher.isOffline { return "wifi.slash" }
        if hasQuoteError { return "exclamationmark.triangle" }
        if refresher.snapshotIsFromCache { return "clock.arrow.circlepath" }
        return "arrow.clockwise"
    }

    private var footerIconColor: Color {
        if refresher.isOffline || hasQuoteError { return .orange }
        if refresher.snapshotIsFromCache { return .orange }
        return .secondary
    }

    private var hasQuoteError: Bool {
        if let err = refresher.lastError {
            return !err.isEmpty
        }
        return false
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }
}

/// 标签拖拽排序的落点代理:拖到某个标签上时实时把被拖标签移到该位置,
/// 松手(performDrop)时才写库,避免拖拽过程中反复落盘。
private struct TabDropDelegate: DropDelegate {
    let item: PopoverViewModel.Tab
    let vm: PopoverViewModel

    func dropEntered(info: DropInfo) {
        guard let dragging = vm.draggingTab, dragging != item else { return }
        var order = vm.tabOrder
        guard let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        order.move(fromOffsets: IndexSet(integer: from),
                   toOffset: to > from ? to + 1 : to)
        vm.reorderTabs(order)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        vm.dragDidDrop()
        return true
    }

    /// 会话取消(松手在空白处 / Esc)时只会走到这里,兜底复位透明度。
    /// 正常在相邻标签间换位时,紧接着的 dropEntered 会取消这个延迟清理。
    func dropExited(info: DropInfo) {
        vm.dragDidExit()
    }
}
