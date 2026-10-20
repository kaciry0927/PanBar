import Foundation

/// Popover 内分时展开行的状态与轮询 owner。
///
/// 获取时机:懒加载(展开才拉)+ 展开期间 30s 轮询,不预拉取、不并入
/// QuoteRefresher 的批量 tick(单标的请求会打乱三档 Pace 语义)。
@MainActor
final class IntradayStore: ObservableObject {
    static let pollInterval: TimeInterval = 30
    /// 上一次拉取失败后的重试间隔(东财瞬态断连是秒级恢复的,失败快速重试)。
    static let errorRetryInterval: TimeInterval = 8

    /// key(IntradayTarget.cacheKey)→ 已加载的分时数据
    @Published private(set) var series: [String: IntradaySeries] = [:]
    @Published private(set) var loadingKeys: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    /// 当前展开的 key(单展开手风琴);UI 直接读它决定是否渲染展开区。
    @Published private(set) var expandedKey: String?

    private var pollTask: Task<Void, Never>?
    private let service: IntradayService
    private let clock: MarketClock

    init(service: IntradayService, clock: MarketClock) {
        self.service = service
        self.clock = clock
    }

    /// 单击行:展开该行(立即拉取 + 启动轮询)或收起。
    func toggle(target: IntradayTarget) {
        let key = target.cacheKey
        if expandedKey == key {
            collapse(key: key)
        } else {
            expandedKey = key
            errors[key] = nil
            startPolling(target: target, key: key)
        }
    }

    private func collapse(key: String) {
        expandedKey = nil
        pollTask?.cancel()
        pollTask = nil
        loadingKeys.remove(key)
    }

    private func startPolling(target: IntradayTarget, key: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop(target: target, key: key)
        }
    }

    private func pollLoop(target: IntradayTarget, key: String) async {
        while !Task.isCancelled {
            let ok = await refreshOnce(target: target, key: key)
            // 失败后 8s 就重试(东财瞬态断连换连接即恢复,没必要陪等 30s);
            // 成功则回到正常轮询间隔
            let interval = ok ? Self.pollInterval : Self.errorRetryInterval
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return   // cancelled
            }
        }
    }

    /// 返回是否成功拿到数据(供轮询决定下一次的等待时长)。
    @discardableResult
    private func refreshOnce(target: IntradayTarget, key: String) async -> Bool {
        // 休市且已有数据:走势不再变化,跳过重拉
        if let market = target.market, clock.status(market) == .closed, series[key] != nil {
            return true
        }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }
        do {
            let s = try await service.fetch(target)
            guard !Task.isCancelled else { return true }
            series[key] = s
            errors[key] = nil
            return true
        } catch {
            guard !Task.isCancelled else { return true }
            // 不展示底层错误细节(如 "PanBar.HTTPError 错误 0"),对用户没有意义;
            // 统一用可操作的文案,点击错误区可立即重试(见 retry)。
            errors[key] = L("intraday.failed", comment: "")
            return false
        }
    }

    /// 手动重试(点击展开区的错误文案):立即重新拉取并重启轮询。
    func retry(target: IntradayTarget, key: String) {
        guard loadingKeys.contains(key) == false else { return }
        errors[key] = nil
        startPolling(target: target, key: key)
    }

    /// Popover 关闭:只停轮询,不动任何 @Published 状态。
    ///
    /// 实测教训:关闭动画期间清空状态会让内容高度骤变,NSPopover 调整窗口尺寸
    /// 触发布局重入,AppKit 在 _postWindowNeedsUpdateConstraints 抛 NSException
    /// → SIGABRT 崩溃。残留状态(展开的行)反正不可见,等下次打开前清理。
    func popoverDidClose() {
        pollTask?.cancel()
        pollTask = nil
        loadingKeys.removeAll()
    }

    /// Popover 打开前(窗口尚未显示,改内容尺寸安全):清理上一次的残留状态。
    func popoverWillOpen() {
        pollTask?.cancel()
        pollTask = nil
        expandedKey = nil
        loadingKeys.removeAll()
        errors.removeAll()
        series.removeAll()   // 跨交易日缓存会过期,打开时重新懒加载
    }
}
