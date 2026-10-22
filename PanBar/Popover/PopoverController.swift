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
    private let appearancePrefs: AppearancePreferences
    private let tickerPrefs: TickerPreferences
    private let container: DependencyContainer
    /// 宽高都由 SwiftUI 内容的自然尺寸决定(preferredContentSize),这里只夹紧
    /// 宽度下限(避免空内容时过窄)和上限(防超长名称撑爆屏幕)。
    private let minimumPopoverWidth: CGFloat = 300
    private let maximumPopoverWidth: CGFloat = 720
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
            settingsRepo: settingsRepo,
            prefs: tickerPrefs
        )
        self.appearancePrefs = appearancePrefs
        self.tickerPrefs = tickerPrefs
        self.container = container

        let popover = NSPopover()
        popover.behavior = .transient
        self.popover = popover  // 先完成全部存储属性初始化,才能调用实例方法
        let host = makeContentController()
        popover.contentViewController = host
        popover.contentSize = host.preferredContentSize

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
        // 分时展开行:停止轮询并清状态(下次打开重新懒加载)
        container.intradayStore.popoverDidClose()
        onClose?()
    }

    func show(relativeTo view: NSView, anchorWidth: CGFloat? = nil) {
        // 在窗口显示前清理上次的分时展开状态(此时改内容尺寸是安全的)
        container.intradayStore.popoverWillOpen()
        refresher.setPopoverOpen(true)
        refresher.refreshNow()
        popover.show(relativeTo: positioningRect(relativeTo: view, anchorWidth: anchorWidth), of: view, preferredEdge: .minY)
        startOutsideClickMonitor()
    }

    /// 构造 popover 内容的 hosting controller。
    /// 尺寸不写死:sizingOptions = [.preferredContentSize] 让 preferredContentSize
    /// 跟随 SwiftUI 内容的自然宽高(各 tab 内部已有 maxHeight 上限,过长时滚动),
    /// NSPopover 会在内容变化(切 tab / 增删持仓等)时自动动画调整大小。
    private func makeContentController() -> NoSafeAreaHostingController<AnyView> {
        let root = PopoverRoot()
            .environmentObject(viewModel)
            .environmentObject(refresher)
            .environmentObject(appearancePrefs)
            .environmentObject(tickerPrefs)
            .environmentObject(container.intradayStore)
            .environment(\.container, container)
            .frame(minWidth: minimumPopoverWidth, maxWidth: maximumPopoverWidth)
            .ignoresSafeArea()
        let host = NoSafeAreaHostingController(rootView: AnyView(root))
        host.sizingOptions = [.preferredContentSize]
        return host
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
