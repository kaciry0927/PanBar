import SwiftUI
import AppKit

/// 把 ScrollView 原生滚动条换成 3pt 细条:短、细、随滚动移动。
///
/// 实现(全部走 AppKit,不依赖 SwiftUI 15+ 的 onScrollGeometryChange):
/// 1. ScrollViewProbe introspect 到 SwiftUI 底层的 NSScrollView
///    (按窗口子树搜索 + frame 相交匹配,定位到自己这个);
/// 2. 直接 `hasVerticalScroller = false` 强杀原生滚动条 —— macOS 上当系统
///    外观是「滚动条始终可见」(legacy scroller)时 `.scrollIndicators(.hidden)`
///    不生效(已知问题),必须走这条路;
/// 3. 监听 clip view 的 boundsDidChange / frameDidChange 通知拿到
///    滚动偏移与内容尺寸,驱动自绘 3pt thumb。
///
/// 用法:挂在 ScrollView 上 —— `ScrollView { ... }.thinScrollbar()`。
struct ThinScrollbarModifier: ViewModifier {
    @State private var info = ScrollInfo(container: 0, content: 0, offset: 0)

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .background(ScrollViewProbe { info = $0 })
            .overlay(alignment: .trailing) {
                thumb
            }
    }

    /// 内容溢出时才显示:trailing 边 2pt 处一根 3pt 宽的圆角细条,
    /// 长度按可视比例(最短 24pt),位置按滚动比例。
    @ViewBuilder
    private var thumb: some View {
        if info.content > info.container + 1 {
            let track = max(info.container - 8, 10)              // 上下各留 4pt
            let maxScroll = max(info.content - info.container, 1)
            let thumbHeight = max(track * info.container / info.content, 24)
            // AppKit clip view 的 bounds.origin.y:滚动越多越大(顶部为 0)
            let progress = min(max(info.offset / maxScroll, 0), 1)
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3, height: thumbHeight)
                .padding(.trailing, 2)
                .offset(y: 4 + progress * (track - thumbHeight))
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }
}

private struct ScrollInfo: Equatable {
    /// 可视区高度(NSScrollView clip view bounds height)
    let container: CGFloat
    /// 内容总高度(documentView frame height)
    let content: CGFloat
    /// 当前滚动偏移(顶部为 0,向下增大)
    let offset: CGFloat
}

/// 空白探针视图,借自己在窗口中的位置找到所属的 NSScrollView 并接管其滚动信息。
/// 不能只走 superview 链(modifier 包裹层可能是 NSScrollView 的兄弟节点),
/// 所以对整个窗口做子树搜索,用 frame 相交挑出自己所属的那个。
private struct ScrollViewProbe: NSViewRepresentable {
    let onChange: (ScrollInfo) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
        nsView.probe()   // 布局/状态变化后重新匹配 + 重报几何 + 重新压制 scroller
    }

    final class ProbeView: NSView {
        var onChange: ((ScrollInfo) -> Void)?
        private var observed: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            probe()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func probe() {
            guard let window, let target = bestScrollView(in: window) else { return }
            attach(to: target)
        }

        /// 窗口里可能有多个 NSScrollView(Tab 切换残留),只挑与自己区域相交的。
        private func bestScrollView(in window: NSWindow) -> NSScrollView? {
            guard let root = window.contentView else { return nil }
            let myFrame = convert(bounds, to: nil)   // 窗口坐标系
            var stack: [NSView] = [root]
            while let v = stack.popLast() {
                if let sv = v as? NSScrollView,
                   sv.convert(sv.bounds, to: nil).intersects(myFrame) {
                    return sv
                }
                stack.append(contentsOf: v.subviews)
            }
            return nil
        }

        private func attach(to sv: NSScrollView) {
            hideNativeScrollers(of: sv)
            guard observed !== sv else { return }
            removeAllObservers()
            observed = sv

            let clip = sv.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            sv.documentView?.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() })
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() })
            if let doc = sv.documentView {
                observers.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: doc, queue: .main
                ) { [weak self] _ in self?.report() })
            }
            report()
        }

        private func report() {
            guard let sv = observed else { return }
            hideNativeScrollers(of: sv)   // SwiftUI 可能在状态更新时重置配置,顺手压制
            let clip = sv.contentView
            let container = clip.bounds.height
            let content = max(sv.documentView?.frame.height ?? 0, container)
            let offset = clip.bounds.origin.y
            onChange?(ScrollInfo(container: container, content: content, offset: offset))
        }

        private func hideNativeScrollers(of sv: NSScrollView) {
            // legacy 滚动条(系统「始终显示滚动条」,外接鼠标常见)会占据内容右侧宽度,
            // 展开分时图内容变高触发 scroller 后,整行(含行尾展开 chevron)被往左挤。
            // 强制 overlay 样式:即使 scroller 短暂显示也浮在内容上、不占宽;
            // hasVerticalScroller = false 再彻底隐藏。双保险,消除布局竞争抖动。
            sv.scrollerStyle = .overlay
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.verticalScroller?.isHidden = true
            sv.horizontalScroller?.isHidden = true
        }

        private func removeAllObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

extension View {
    /// 把 ScrollView 的原生滚动条替换为 3pt 细条(见 ThinScrollbarModifier)。
    func thinScrollbar() -> some View {
        modifier(ThinScrollbarModifier())
    }
}
