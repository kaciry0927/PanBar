import XCTest
@testable import PanBar

/// tab 顺序同步契约:popover 拖拽与设置页「标签页显隐」共用
/// `TickerPreferences.popoverTabOrder` 这一份真相源。
///
/// 这里覆盖两件曾经踩坑的事:
///   1. 顺序归一化(去重 / 丢弃非法值 / 补齐新增 tab)必须只有一处实现;
///   2. 拖拽写入后落库,新实例(模拟设置窗口的读库路径)必须读到同一顺序。
final class TabOrderTests: XCTestCase {
    private var dbPath: String!
    private var database: Database!
    private var repo: SettingsRepository!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "panbar-taborder-\(UUID().uuidString).sqlite"
        database = try Database(path: dbPath)
        repo = SettingsRepository(dbPool: database.dbPool)
    }

    override func tearDownWithError() throws {
        database = nil
        repo = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
    }

    // MARK: - 归一化

    func testEmptyOrderFallsBackToDefaultOrder() {
        XCTAssertEqual(PopoverViewModel.Tab.ordered(from: []), PopoverViewModel.Tab.allCases)
    }

    func testOrderDropsDuplicatesAndUnknownValuesThenBackfillsMissing() {
        let order = PopoverViewModel.Tab.ordered(from: ["sectors", "sectors", "bogus", "holdings"])
        XCTAssertEqual(order, [.sectors, .holdings, .watchlist, .indices, .alerts])
    }

    // MARK: - 跨窗口同步

    @MainActor
    func testDraggedOrderIsPersistedAndReadBackByNewPreferencesInstance() throws {
        let prefs = TickerPreferences(repo: repo)
        XCTAssertEqual(prefs.popoverTabOrder, [])   // 首次运行:库里没有顺序

        // 模拟 popover 拖拽 → PopoverViewModel.reorderTabs 写的正是这个属性
        let dragged = ["sectors", "watchlist", "holdings", "indices", "alerts"]
        prefs.popoverTabOrder = dragged

        XCTAssertEqual(repo.string(SettingsRepository.Keys.popoverTabOrder),
                       dragged.joined(separator: ","))

        // 设置窗口的 GeneralPane 读的是同一实例;新实例代表重启后重新读库
        let reloaded = TickerPreferences(repo: repo)
        XCTAssertEqual(reloaded.popoverTabOrder, dragged)
    }

    @MainActor
    func testEmptyOrderNeverOverwritesPersistedValue() throws {
        let prefs = TickerPreferences(repo: repo)
        let dragged = ["alerts", "sectors", "indices", "watchlist", "holdings"]
        prefs.popoverTabOrder = dragged

        // 防御:空数组(未初始化)不允许把已保存的顺序冲掉
        prefs.popoverTabOrder = []
        XCTAssertEqual(repo.string(SettingsRepository.Keys.popoverTabOrder),
                       dragged.joined(separator: ","))
    }
}
