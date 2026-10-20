import Foundation

/// 分时序列中的一个采样点。
/// x 轴用等距序号 seq 而非真实时间:A 股午休 11:30–13:00 会被拼接掉,
/// 若用真实时间画图会在中间留一小时空洞。
struct IntradayPoint: Sendable, Equatable {
    let seq: Int
    let price: Double
    /// 均价线(VWAP)。
    let avgPrice: Double
}

/// 当日分时曲线数据:价格线 + 均价线 + 昨收参考线。
struct IntradaySeries: Sendable, Equatable {
    /// 缓存 key:股票用 SymbolID.storageKey,指数用 IndexDescriptor.id。
    let cacheKey: String
    /// 昨收(图上画虚线参考线,也决定价格线涨跌配色)。
    let prevClose: Double
    let points: [IntradayPoint]
    /// 午休分界的 seq(午后第一行的序号,如 A 股 13:00);无午休市场为 nil。
    /// 供 x 轴在数据坐标系内精确标注午休位置。
    let midSeq: Int?
    /// 收盘时刻的 seq:x 轴域扩展到整日(0...closeSeq),盘中时曲线按比例停在
    /// 当前时刻,收盘时间标签始终对齐图表右缘(与主流行情 App 一致)。
    let closeSeq: Int
    /// 开盘时间标签,如 "09:30"。
    let openTimeLabel: String
    /// 午休标注,如 "11:30/13:00";无午休的市场(美股)为 nil。
    let midTimeLabel: String?
    /// 收盘时间标签,如 "15:00" / "16:00"。
    let closeTimeLabel: String
    let fetchedAt: Date
}

/// 分时请求目标:股票(自选/持仓)或指数(大盘)。
enum IntradayTarget: Sendable, Hashable {
    case stock(SymbolID)
    case index(IndexDescriptor)

    var cacheKey: String {
        switch self {
        case .stock(let s): return s.storageKey
        case .index(let d): return d.id
        }
    }

    /// 指数可能是全球指数(market 为 nil),此时不做休市跳过优化。
    var market: Market? {
        switch self {
        case .stock(let s): return s.market
        case .index(let d): return d.market
        }
    }
}
