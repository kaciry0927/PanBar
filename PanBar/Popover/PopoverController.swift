import AppKit
import SwiftUI

/// NSPopover + NSHostingController 的经典问题:hosting view 会把 popover 的箭头
/// 锚定区算进 safe area,内容顶部因此多出一大块空白。
/// 注意:macOS 上只覆盖 safeAreaInsets 不够(NSHostingView 可能走 safeAreaRect
/// 或内部缓存),所以 safeAreaRect 一并覆盖;SwiftUI 侧再加 .ignoresSafeArea() 兜底。
private final class NoSafeAreaHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    override var safeAreaRect: NSRect { bounds }
}

private final class NoSafeAreaHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = NoSafeAreaHostingView(rootView: rootView)
    }
}

@MainActor
final class PopoverController {
    private let popover: NSPopover
    private let refresher: QuoteRefresher
    private let viewModel: PopoverViewModel
    private let holdingsRepo: HoldingsRepository
    private let appearancePrefs: AppearancePreferences
    private let tickerPrefs: TickerPreferences
    private let container: DependencyContainer
    private let minimumPopoverWidth: CGFloat = 360
    private let popoverHeight: CGFloat = 520
    private let metricsGridWidth: CGFloat = 104
    /// 监听 popover 之外的点击,关 popover。`.transient` 行为对菜单栏 popover 有时漏
    /// (尤其是点系统菜单栏 / 通知 / 其它 app 时),这里多加一层保险。
    private var eventMonitor: Any?
    private var didCloseObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    var isShown: Bool { popover.isShown }

    init(
        refresher: QuoteRefresher,
        holdingsRepo: HoldingsRepository,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository,
        appearancePrefs: AppearancePreferences,
        tickerPrefs: TickerPreferences,
        container: DependencyContainer
    ) {
        self.refresher = refresher
        self.viewModel = PopoverViewModel(
            refresher: refresher,
            holdingsRepo: holdingsRepo,
            watchlistRepo: watchlistRepo,
            settingsRepo: settingsRepo
        )
        self.holdingsRepo = holdingsRepo
        self.appearancePrefs = appearancePrefs
        self.tickerPrefs = tickerPrefs
        self.container = container

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.contentViewController = NoSafeAreaHostingController(rootView:
            PopoverRoot()
                .environmentObject(viewModel)
                .environmentObject(refresher)
                .environmentObject(appearancePrefs)
                .environmentObject(tickerPrefs)
                .environment(\.container, container)  // 修复:之前没注入,导致 IndicesTab 拿不到 indexService
                .frame(width: 360, height: 520)
                .ignoresSafeArea()
        )
        self.popover = popover

        // popover 通过 .transient 行为自己关时,也要更新 refresher 状态
        // (否则 pace 会一直停在 .popoverOpen,后台多耗一点请求)
        didCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePopoverClosed()
            }
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        if let observer = didCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handlePopoverClosed() {
        stopOutsideClickMonitor()
        refresher.setPopoverOpen(false)
        onClose?()
    }

    func show(relativeTo view: NSView, anchorWidth: CGFloat? = nil) {
        let width = preferredPopoverWidth(screen: view.window?.screen)
        applyContentWidth(width)
        refresher.setPopoverOpen(true)
        refresher.refreshNow()
        popover.show(relativeTo: positioningRect(relativeTo: view, anchorWidth: anchorWidth), of: view, preferredEdge: .minY)
        startOutsideClickMonitor()
    }

    private func applyContentWidth(_ width: CGFloat) {
        popover.contentSize = NSSize(width: width, height: popoverHeight)
        popover.contentViewController = NoSafeAreaHostingController(rootView:
            PopoverRoot()
                .environmentObject(viewModel)
                .environmentObject(refresher)
                .environmentObject(appearancePrefs)
                .environmentObject(tickerPrefs)
                .environment(\.container, container)
                .frame(width: width, height: popoverHeight)
                .ignoresSafeArea()
        )
    }

    private func preferredPopoverWidth(screen: NSScreen?) -> CGFloat {
        let holdings = (try? holdingsRepo.all()) ?? viewModel.holdings
        guard !holdings.isEmpty else { return minimumPopoverWidth }

        let positionsByID = Dictionary(uniqueKeysWithValues: refresher.snapshot.positions.map { ($0.holding.id, $0) })
        var widestRow: CGFloat = minimumPopoverWidth

        for holding in holdings {
            let quote = refresher.quotes[holding.symbol] ?? positionsByID[holding.id]?.quote
            widestRow = max(widestRow, estimatedHoldingRowWidth(holding: holding, quote: quote))
        }

        return min(maximumPopoverWidth(screen: screen), max(minimumPopoverWidth, ceil(widestRow)))
    }

    private func estimatedHoldingRowWidth(holding: Holding, quote: Quote?) -> CGFloat {
        let position = refresher.snapshot.positions.first { $0.holding.id == holding.id }
        let rowPadding = appearancePrefs.density.rowHorizontalPadding * 2
        let titleWidth = textWidth(displayCode(holding.symbol), size: 11, weight: .regular)
            + 4
            + textWidth(holding.name, size: 12, weight: .semibold)
            + 14
        let detailWidth = textWidth(detailText(for: holding), size: 10, weight: .regular)
        let leftWidth = max(titleWidth, detailWidth)
        let metricsWidth = max(metricsGridWidth, estimatedMetricsGridWidth(holding: holding, quote: quote, position: position))

        return leftWidth + 8 + metricsWidth + rowPadding + 14
    }

    private func maximumPopoverWidth(screen: NSScreen?) -> CGFloat {
        let screenWidth = (screen ?? NSScreen.main)?.visibleFrame.width ?? 900
        return max(minimumPopoverWidth, min(760, screenWidth - 80))
    }

    private func estimatedMetricsGridWidth(holding: Holding, quote: Quote?, position: HoldingPosition?) -> CGFloat {
        let metricMode = holdingPopoverMetric
        return max(
            estimatedQuoteWidth(holding: holding, quote: quote),
            metricLineWidth(
                label: metricMode.displayName,
                value: nativeMetric(holding: holding, quote: quote, mode: metricMode),
                currency: holding.currency
            ),
            baseMetricWidth(value: baseMetric(position: position, mode: metricMode))
        )
    }

    private func metricLineWidth(label: String, value: Decimal?, currency: Currency) -> CGFloat {
        textWidth(label, size: 10, weight: .medium)
            + 3
            + textWidth(value.map { signedPnL($0, currency: currency) } ?? "—", size: 11, weight: .semibold)
    }

    private func baseMetricWidth(value: Decimal?) -> CGFloat {
        textWidth(value.map { "≈ " + signedPnL($0, currency: refresher.snapshot.baseCurrency) } ?? "—", size: 11, weight: .semibold)
    }

    private var holdingPopoverMetric: HoldingPopoverMetric {
        HoldingPopoverMetric(rawValue: container.settingsRepo.string(SettingsRepository.Keys.holdingPopoverMetric) ?? "") ?? .allTime
    }

    private func nativePnL(holding: Holding, quote: Quote?) -> Decimal? {
        guard let quote else { return nil }
        return (quote.price - holding.costPrice) * holding.quantity
    }

    private func nativeTodayPnL(holding: Holding, quote: Quote?) -> Decimal? {
        guard let quote else { return nil }
        return (quote.price - quote.prevClose) * holding.quantity
    }

    private func nativeMetric(holding: Holding, quote: Quote?, mode: HoldingPopoverMetric) -> Decimal? {
        switch mode {
        case .allTime:
            return nativePnL(holding: holding, quote: quote)
        case .today:
            return nativeTodayPnL(holding: holding, quote: quote)
        }
    }

    private func baseMetric(position: HoldingPosition?, mode: HoldingPopoverMetric) -> Decimal? {
        switch mode {
        case .allTime:
            return position?.basePnL
        case .today:
            return position?.baseTodayPnL
        }
    }

    private func estimatedQuoteWidth(holding: Holding, quote: Quote?) -> CGFloat {
        guard let quote else {
            return textWidth("—", size: 12, weight: .semibold)
        }
        let price = holding.currency.format(quote.price, fractionDigits: tickerPrefs.priceFractionDigits)
        let pct = String(format: "%+.2f%%", quote.changePct * 100)
        return textWidth(price, size: 12, weight: .semibold)
            + 5
            + textWidth(pct, size: 10, weight: .semibold)
            + 10
    }

    private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func displayCode(_ symbol: SymbolID) -> String {
        symbol.market == .us ? symbol.code.uppercased() : symbol.code
    }

    private func detailText(for holding: Holding) -> String {
        let qtyDisplay = "\(holding.quantity)"
        let costDisplay = holding.currency.format(holding.costPrice, fractionDigits: 3)
        return String(format: L("holding.detail", comment: ""), qtyDisplay, costDisplay)
    }

    private func signedPnL(_ value: Decimal, currency: Currency) -> String {
        let sign = value >= 0 ? "+" : "-"
        return sign + currency.format(value.magnitude)
    }

    private func positioningRect(relativeTo view: NSView, anchorWidth: CGFloat?) -> NSRect {
        let rect: NSRect
        if let anchorWidth {
            let width = max(view.bounds.width, anchorWidth)
            rect = NSRect(
                x: view.bounds.maxX - width,
                y: view.bounds.minY,
                width: width,
                height: view.bounds.height
            )
        } else {
            rect = view.bounds
        }
        return rect
    }

    func close() {
        stopOutsideClickMonitor()
        popover.performClose(nil)
        refresher.setPopoverOpen(false)
    }

    /// 全局监听点击事件,任何 popover 之外的点都关掉它。
    /// 不用 local monitor 是因为 local 只捕获本 app 内,系统菜单栏 / 通知中心捕不到。
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // 全局监听拿到事件 = 用户点了别处(popover 是 app 内的,本 app 内点击不会进 global monitor)
            DispatchQueue.main.async {
                guard let self = self, self.popover.isShown else { return }
                self.close()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
