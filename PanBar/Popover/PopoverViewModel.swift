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
    }

    @Published var currentTab: Tab = .holdings
    /// 标签栏显示顺序(可拖拽调整,持久化到 appSetting)
    @Published private(set) var tabOrder: [Tab] = Tab.allCases
    @Published var holdings: [Holding] = []
    @Published var watchlist: [WatchItem] = []

    let refresher: QuoteRefresher
    let holdingsRepo: HoldingsRepository
    let watchlistRepo: WatchlistRepository
    let settingsRepo: SettingsRepository

    private var observationTasks: [Task<Void, Never>] = []

    init(
        refresher: QuoteRefresher,
        holdingsRepo: HoldingsRepository,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository
    ) {
        self.refresher = refresher
        self.holdingsRepo = holdingsRepo
        self.watchlistRepo = watchlistRepo
        self.settingsRepo = settingsRepo
        loadTabOrder()
        reload()
        startObserving()
    }

    /// 从 appSetting 读取标签顺序;缺省/非法值/新增 tab 兜底补齐
    private func loadTabOrder() {
        guard let raw = settingsRepo.string(SettingsRepository.Keys.popoverTabOrder) else { return }
        var ids = raw.split(separator: ",").compactMap { Tab(rawValue: String($0)) }
        // 去重
        var seen = Set<Tab>()
        ids = ids.filter { seen.insert($0).inserted }
        // 补齐新增的 tab(版本升级后 allCases 里可能有新成员)
        let missing = Tab.allCases.filter { !ids.contains($0) }
        tabOrder = ids + missing
    }

    /// 拖拽过程中实时更新顺序(不落盘)
    func reorderTabs(_ newOrder: [Tab]) {
        guard newOrder.count == Tab.allCases.count, newOrder.map(\.id).sorted() == Tab.allCases.map(\.id).sorted() else { return }
        tabOrder = newOrder
    }

    /// 拖拽结束后落盘
    func persistTabOrder() {
        let raw = tabOrder.map(\.rawValue).joined(separator: ",")
        try? settingsRepo.set(SettingsRepository.Keys.popoverTabOrder, raw)
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

    /// performDrop:落盘顺序并结束拖拽态。
    func dragDidDrop() {
        dragCleanupWork?.cancel()
        dragCleanupWork = nil
        draggingTab = nil
        persistTabOrder()
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
