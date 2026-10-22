import Foundation
import Combine

@MainActor
final class PopoverViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case holdings, watchlist, indices, sectors, alerts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .holdings:  return L("tab.holdings", comment: "")
            case .watchlist: return L("tab.watchlist", comment: "")
            case .indices:   return L("tab.indices", comment: "")
            case .sectors:   return L("tab.sectors", comment: "")
            case .alerts:    return L("tab.alerts", comment: "")
            }
        }

        /// 把持久化的 rawValue 顺序还原成完整、合法的顺序:解析失败项丢弃、去重、
        /// 再按 allCases 补齐缺失项(版本升级后新增的 tab 落在末尾)。
        /// popover 拖拽排序与设置页「标签页显隐」共用此方法,保证两处顺序同源。
        static func ordered(from rawIDs: [String]) -> [Tab] {
            var seen = Set<Tab>()
            let ids = rawIDs.compactMap(Tab.init(rawValue:)).filter { seen.insert($0).inserted }
            return ids + Tab.allCases.filter { !seen.contains($0) }
        }
    }

    @Published var currentTab: Tab = .holdings
    /// 标签栏显示顺序:直接由 prefs.popoverTabOrder(拖拽排序的真相源)派生,
    /// 不在 VM 里另存一份,避免「popover 拖了、设置页没跟着变」的两份状态。
    var tabOrder: [Tab] { Tab.ordered(from: prefs.popoverTabOrder) }
    @Published var holdings: [Holding] = []
    @Published var watchlist: [WatchItem] = []

    let refresher: QuoteRefresher
    let holdingsRepo: HoldingsRepository
    let watchlistRepo: WatchlistRepository
    let settingsRepo: SettingsRepository
    /// 与设置窗口共享的偏好对象;tab 顺序经它广播给设置页。
    let prefs: TickerPreferences

    private var observationTasks: [Task<Void, Never>] = []

    init(
        refresher: QuoteRefresher,
        holdingsRepo: HoldingsRepository,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository,
        prefs: TickerPreferences
    ) {
        self.refresher = refresher
        self.holdingsRepo = holdingsRepo
        self.watchlistRepo = watchlistRepo
        self.settingsRepo = settingsRepo
        self.prefs = prefs
        loadTabOrder()
        reload()
        startObserving()
    }

    /// 首次运行(库里没有顺序)或版本升级新增 tab 时,把默认值 / 缺失项补进
    /// prefs.popoverTabOrder。normalized 与库中原值一致时完全不写,避免启动即落库。
    private func loadTabOrder() {
        let stored = prefs.popoverTabOrder
        let normalized = Tab.ordered(from: stored).map(\.rawValue)
        guard normalized != stored else { return }
        prefs.popoverTabOrder = normalized
    }

    /// 拖拽过程中实时更新顺序 —— 写 prefs 即落库并广播给设置页,
    /// 因此设置页「标签页显隐」会在拖拽时同步重排,不需要重开设置窗口。
    func reorderTabs(_ newOrder: [Tab]) {
        let ids = newOrder.map(\.rawValue)
        guard ids.count == Tab.allCases.count,
              Set(ids) == Set(Tab.allCases.map(\.rawValue)) else { return }
        prefs.popoverTabOrder = ids
    }

    // MARK: 标签拖拽状态

    /// 正在拖拽的标签(仅用于把源标签压暗到 0.4 透明度)。
    /// 状态放 VM 而非视图 @State:拖拽会话被取消时(松手在空白处 / 按 Esc)
    /// SwiftUI 不会回调 performDrop,只有最后经过的目标收到 dropExited ——
    /// 必须在那里兜底清理,否则被拖过的标签会永远停在半透明上。
    @Published var draggingTab: Tab?

    private var dragCleanupWork: DispatchWorkItem?

    /// dropEntered / onDrag:记录拖拽源,并取消待执行的兜底清理
    /// (exited → entered 之间只有几毫秒,不能让 exited 的延迟清理误伤正常换位)。
    func dragDidEnter(_ tab: Tab?) {
        dragCleanupWork?.cancel()
        dragCleanupWork = nil
        draggingTab = tab
    }

    /// dropExited:延迟一拍再清理。路过相邻标签时,下一个 dropEntered 会
    /// 取消清理;会话真被取消(不再有任何回调)时,这里负责把透明度复位。
    func dragDidExit() {
        dragCleanupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.draggingTab = nil }
        dragCleanupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// performDrop:结束拖拽态。顺序已在 dropEntered → reorderTabs 里写入
    /// prefs(并落库),这里不再重复落盘。
    func dragDidDrop() {
        dragCleanupWork?.cancel()
        dragCleanupWork = nil
        draggingTab = nil
    }

    func reload() {
        holdings = (try? holdingsRepo.all()) ?? []
        watchlist = (try? watchlistRepo.all()) ?? []
    }

    private func startObserving() {
        let h = Task { [weak self] in
            guard let stream = self?.holdingsRepo.observeAll() else { return }
            for await items in stream {
                await MainActor.run { self?.holdings = items }
            }
        }
        let w = Task { [weak self] in
            guard let stream = self?.watchlistRepo.observeAll() else { return }
            for await items in stream {
                await MainActor.run { self?.watchlist = items }
            }
        }
        observationTasks = [h, w]
    }

    func deleteHolding(_ id: UUID) {
        try? holdingsRepo.delete(id: id)
        refresher.refreshNow()
    }

    func deleteWatchItem(_ id: UUID) {
        try? watchlistRepo.delete(id: id)
        refresher.refreshNow()
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }
}
