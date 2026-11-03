import Foundation
import ServiceManagement

/// 包装 SMAppService 实现 macOS 13+ 的开机启动。
enum LaunchAtLoginService {
    /// 进程内缓存的启用状态。
    ///
    /// `SMAppService.mainApp.status` 是一次同步 XPC 往返(macOS 26 实测几十到
    /// 几百 ms)。GeneralPane 曾把它直接写在 `@State` 默认值里 —— SwiftUI 的
    /// 默认值表达式在每次构造视图结构体时都会求值,表现为:打开设置页、每次
    /// 切回「通用」tab 都同步打一次 XPC,设置页切 tab 明显卡顿。
    /// 现在统一走缓存:XPC 只发生在后台预热 / 后台刷新 / 用户改开关时。
    @MainActor
    private static var cachedEnabled: Bool?

    /// 同步读缓存。缓存未预热时(进程刚启动就立刻开设置页的极端时序)才同步
    /// 打一次 XPC,之后整个进程生命周期都不再在主线程同步等 XPC。
    @MainActor
    static var isCachedEnabled: Bool {
        if let cached = cachedEnabled { return cached }
        let value = readSystemState()
        cachedEnabled = value
        return value
    }

    /// 后台取一次系统真值并写缓存,返回真值。用于进程启动预热和设置页
    /// onAppear 校准(用户可能在系统设置里改过登录项)。
    @MainActor
    static func refreshCacheInBackground() async -> Bool {
        let value = await Task.detached(priority: .userInitiated) {
            readSystemState()
        }.value
        cachedEnabled = value
        return value
    }

    /// 同步读系统真值。只应在后台线程 / 初始化兜底调用,不要放进 SwiftUI
    /// 视图初始化路径。
    private static func readSystemState() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 同步 XPC(register/unregister/status 检查),只在用户拨动开关时调用,
    /// 不进视图初始化路径。调用方(SwiftUI onChange)本来就在主线程。
    @MainActor
    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            if SMAppService.mainApp.status == .enabled {
                cachedEnabled = true
                return
            }
            try SMAppService.mainApp.register()
        } else {
            if SMAppService.mainApp.status == .notFound {
                cachedEnabled = false
                return
            }
            try SMAppService.mainApp.unregister()
        }
        cachedEnabled = enabled
    }
}
