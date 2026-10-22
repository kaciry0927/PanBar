import Foundation

/// 行业板块榜单的一行数据(东财 `clist/get` 行业板块接口)。
struct SectorBoard: Identifiable, Hashable, Sendable {
    /// 板块代码,如 "BK1307"。
    let code: String
    /// 板块名称,如 "电机Ⅲ"。
    let name: String
    /// 板块涨跌幅 %(已是百分数,4.55 表示 +4.55%)。
    let changePct: Double
    /// 领涨股名称(f128)。
    let leadingStock: String?
    /// 领涨股涨跌幅 %(f136,已是百分数)。
    let leadingStockChangePct: Double?
    /// 板块内上涨家数(f104)。
    let upCount: Int
    /// 板块内下跌家数(f105)。
    let downCount: Int

    var id: String { code }
}
