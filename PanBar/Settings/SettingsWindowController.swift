import AppKit
import SwiftUI

/// 设置窗口的导航状态。用 ObservableObject 而不是 @State,是为了让 popover
/// 后续多次发起「跳到某 pane」请求时,已存在的窗口能正确切过去 —— @State 初值
/// 只算一次,旧 bug 就是这个。
@MainActor
final class SettingsNavigation: ObservableObject {
    /// 保持 Optional 仅为了对外兼容(show(pane:) / preferredPane 会写非 nil 值)。
    /// 侧边栏现在是显式 Button 高亮(见 SettingsSidebarRow),不依赖 List(selection:),
    /// 也就不存在 List 内部清 nil 引发的锁死问题;展示统一走 ?? .general。
    @Published var selectedPane: SettingsRootView.Pane? = .general
    @Published var pendingAction: SettingsWindowController.PendingAction?
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    let navigation = SettingsNavigation()
    private var window: NSWindow?

    /// 由 popover 触发的"快速添加 / 编辑":打开设置 + 自动跳到目标 pane + 自动弹对应 sheet。
    /// PortfolioPane / WatchlistPane / AlertsPane 启动时会读这个标记并消费。
    enum PendingAction: Equatable {
        case addHolding
        case addWatch
        case addAlert
        case editHolding(UUID)
    }

    /// 兼容旧 API:目标 pane 想用静态属性时仍可写,但 navigation.selectedPane 是真相源。
    static var preferredPane: SettingsRootView.Pane? {
        get { nil }
        set {
            if let pane = newValue {
                shared.navigation.selectedPane = pane
            }
        }
    }

    /// 兼容旧 API:Pane 启动时读 pendingAction 并清空。
    static var pendingAction: PendingAction? {
        get { shared.navigation.pendingAction }
        set { shared.navigation.pendingAction = newValue }
    }

    /// 继承 NSObject 是为了 conform NSWindowDelegate(NSObjectProtocol 要求)。
    private override init() {}

    func show(initialAction: PendingAction? = nil) {
        navigation.pendingAction = initialAction
        if let initialAction = initialAction {
            navigation.selectedPane = pane(for: initialAction)
        }
        showWindow()
    }

    func show() {
        showWindow()
    }

    func show(pane: SettingsRootView.Pane) {
        navigation.selectedPane = pane
        showWindow()
    }

    private func pane(for action: PendingAction) -> SettingsRootView.Pane {
        switch action {
        case .addHolding, .editHolding: return .portfolio
        case .addWatch:                 return .watchlist
        case .addAlert:                 return .alerts
        }
    }

    private func showWindow() {
        // LSUIElement(.accessory) app 的窗口默认拿不到 key/first responder:
        // NSApp.activate() 对 accessory app 基本无效,窗口虽显示却是非激活态 ——
        // 表现为控件灰掉、点第一下才唤醒、sheet 挂不上(见诊断日志)。
        // 打开真窗口前临时切到 .regular,让 AppKit 正常激活并给窗口 key 状态;
        // 关闭后切回 .accessory,保持菜单栏 app 不占 Dock。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = window, window.isVisible {
            window.ensureVisibleOnScreen() // 外接屏拔掉后窗口可能悬在已不存在的屏幕坐标上
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            logWindowState(window, phase: "reuse")
            return
        }
        // window 可能在 windowWillClose 的异步清理窗口里(已关闭但引用还在)。
        // 直接清空重建,别对正在关闭的窗口 makeKeyAndOrderFront(无效,像"卡住")。
        window = nil
        guard let container = DependencyContainer.shared else { return }
        let view = SettingsRootView()
            .environmentObject(container.refresher)
            .environmentObject(navigation)
            .environment(\.container, container)
            .frame(minWidth: 600, minHeight: 480)

        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = L("settings.title", comment: "")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 720, height: 640))
        w.minSize = NSSize(width: 600, height: 480)
        w.forceCenterOnMainScreen()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        logWindowState(w, phase: "create")
    }

    /// 记录窗口是否拿到 key/激活状态。用户报"卡住/图标灰/功能点不动"时,
    /// 这些值是第一手证据:accessory 下通常 isActive=false、isKeyWindow=false。
    private func logWindowState(_ w: NSWindow, phase: String) {
        // 延迟到下一个 runloop:,makeKeyAndOrderFront 后 AppKit 才完成 key 状态更新
        DispatchQueue.main.async {
            let policy = NSApp.activationPolicy().rawValue
            Log.ui.info("设置窗口[\(phase, privacy: .public)]: policy=\(policy) isActive=\(NSApp.isActive) isKey=\(w.isKeyWindow) visible=\(w.isVisible)")
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// 关闭即销毁窗口。设置窗口之前是永久复用的,任何卡死的 SwiftUI presentation
    /// 状态(sheet 挂死 / 侧边栏选中态错乱 / first responder 异常)会随缓存窗口
    /// 一直活着,表现为「关掉设置再打开还是冻着」。销毁后每次打开都是全新
    /// SwiftUI 树;选中的 pane 记在 SettingsNavigation(独立持有)里,重开不丢。
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // 下一个 runloop 再置 nil:windowWillClose 回调期间 AppKit 还在用这个窗口,
        // 同步释放最后一个强引用有deinit 时机上的风险,推迟一拍最稳。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 只清"仍在关闭的那一个"。若期间用户已经重开(window 换成新窗口),
            // 这次延迟清理绝不能误清新窗口 —— 否则 controller 丢失对新窗口的
            // 引用,下次 show 又建一个,旧的永远关不掉。
            guard self.window == nil || self.window === closing else { return }
            self.window = nil
            // 没有其它可见内容窗口(状态栏窗口不算)时切回 .accessory,
            // 保持菜单栏 app 不占 Dock。
            let otherContent = NSApp.windows.contains {
                $0.isVisible && $0 !== closing && !$0.className.contains("StatusBar")
            }
            if !otherContent {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private struct ContainerKey: EnvironmentKey {
    static let defaultValue: DependencyContainer? = nil
}

extension EnvironmentValues {
    var container: DependencyContainer? {
        get { self[ContainerKey.self] }
        set { self[ContainerKey.self] = newValue }
    }
}

struct SettingsRootView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, ticker, portfolio, watchlist, alerts, dataSources, fx, markets, about
        #if DEBUG
        case debug
        #endif

        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:     return L("settings.general", comment: "")
            case .ticker:      return L("settings.ticker", comment: "")
            case .portfolio:   return L("settings.portfolio", comment: "")
            case .watchlist:   return L("settings.watchlist", comment: "")
            case .alerts:      return L("settings.alerts", comment: "")
            case .dataSources: return L("settings.dataSources", comment: "")
            case .fx:          return L("settings.fx", comment: "")
            case .markets:     return L("settings.markets", comment: "")
            case .about:       return L("settings.about", comment: "")
            #if DEBUG
            case .debug:       return "Debug"
            #endif
            }
        }
        var icon: String {
            switch self {
            case .general:     return "gear"
            case .ticker:      return "text.line.first.and.arrowtriangle.forward"
            case .portfolio:   return "briefcase"
            case .watchlist:   return "star"
            case .alerts:      return "bell"
            case .dataSources: return "antenna.radiowaves.left.and.right"
            case .fx:          return "dollarsign.arrow.circlepath"
            case .markets:     return "clock"
            case .about:       return "info.circle"
            #if DEBUG
            case .debug:       return "ladybug"
            #endif
            }
        }
    }

    @EnvironmentObject private var navigation: SettingsNavigation

    /// 当前生效的 pane。selectedPane 保持 Optional(对外 API 兼容),展示统一走 ?? .general。
    private var currentPane: SettingsRootView.Pane {
        navigation.selectedPane ?? .general
    }

    var body: some View {
        NavigationSplitView {
            // 注意:List 故意不用 selection: 绑定(那是 macOS 上侧边栏锁死
            // bug 的根源 —— List 内部选中态与外部绑定脱同步)。点击由行内
            // Button 处理,高亮由 listRowBackground 按 navigation 状态画。
            // 没有隐藏选中状态,就不存在脱同步;原生侧边栏材质/行高照常保留。
            List {
                ForEach(Pane.allCases) { pane in
                    SettingsSidebarRow(
                        pane: pane,
                        isSelected: currentPane == pane
                    ) {
                        navigation.selectedPane = pane
                    }
                    .listRowBackground(
                        Group {
                            if currentPane == pane {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.25))
                                    .padding(.horizontal, 6)
                            }
                        }
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            Group {
                switch currentPane {
                case .general:     GeneralPane()
                case .ticker:      TickerPane()
                case .portfolio:   PortfolioPane()
                case .watchlist:   WatchlistPane()
                case .alerts:      AlertsPane()
                case .dataSources: DataSourcesPane()
                case .fx:          FXPane()
                case .markets:     MarketsPane()
                case .about:       AboutPane()
                #if DEBUG
                case .debug:       DebugPane()
                #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 侧边栏单行:普通 Button + 外部 listRowBackground 高亮。
/// 不用 List(selection:) 的原因见 body 内注释 —— macOS 上 List 的选中态
/// 内部缓存与外部绑定脱同步会导致整栏锁死(0b88219 改 Optional 只堵了一半)。
private struct SettingsSidebarRow: View {
    let pane: SettingsRootView.Pane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(pane.title, systemImage: pane.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .primary : .secondary)
    }
}
