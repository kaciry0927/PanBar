import AppKit

// 窗口屏幕定位工具。
//
// 背景:`NSWindow.center()` 依赖窗口"当前所在屏幕"的历史状态,在以下场景会把
// 窗口摆到用户看不见的地方(表现为"进程在跑但窗口消失"):
//   - 外接显示器拔掉后,屏幕配置缓存未刷新,坐标落在已不存在的屏幕上;
//   - 多屏环境下主屏判定与用户预期不符。
// 这里改用 `NSScreen.main` 的 `visibleFrame` 显式计算坐标,不依赖窗口历史状态,
// 并且在窗口复用(再次打开设置/引导)时做兜底检查。
extension NSWindow {
    /// 强制把窗口移到主屏可见区域内并居中。
    ///
    /// 窗口比可见区域大时收缩窗口尺寸,保证完整落在屏幕内。
    /// 注意:必须在窗口完成 `setContentSize` 之后再调用。
    @MainActor
    func forceCenterOnMainScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(frame.width, visible.width),
            height: min(frame.height, visible.height)
        )
        setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    /// 兜底:窗口与任何屏幕的可见区域都没有交集时,拉回主屏居中;
    /// 位置正常则不动,尊重用户自己的摆放。
    @MainActor
    func ensureVisibleOnScreen() {
        let frame = self.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onScreen {
            forceCenterOnMainScreen()
        }
    }
}
