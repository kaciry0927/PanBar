import Foundation

/// 期货合约描述符(主力/连续)。与 IndexDescriptor 同构:不复用 SymbolID,
/// 因为外盘期货代码空间与 Market 枚举(a/hk/us)不匹配,且交易时段模型不同
/// (纳指/布油近全天候、日经有午休+夜盘),走独立 service 通道。
struct FuturesDescriptor: Identifiable, Hashable, Sendable {
    /// 数据源:新浪外盘期货(实时行情 + 分时)。
    /// symbol 为去掉 hf_ 前缀的代码(实时行拼 hf_ 前缀,分时直接用)。
    enum Source: Hashable, Sendable {
        case sina(symbol: String)
    }

    /// 稳定标识,同时作为 popover 隐藏集合与分时 cacheKey。
    /// 注意不要与 IndexCatalog 的 id 重合(KOSPI 指数 id 就是 "KOSPI"),
    /// 否则分时缓存/展开状态会跨 tab 串扰。
    let id: String
    let nameZh: String
    let nameEn: String
    /// 行副标题:交易所/合约类型说明。
    let subtitleZh: String
    let subtitleEn: String
    let source: Source

    var displayName: String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? nameZh : nameEn
    }

    var subtitle: String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? subtitleZh : subtitleEn
    }
}

/// 期货主力连续固定目录(与 IndexCatalog 同模式:硬编码,顺序即展示顺序)。
/// 全部走新浪外盘通道。曾用东财 100.KS11 现货顶替韩国期指,已移除。
enum FuturesCatalog {
    static let all: [FuturesDescriptor] = [
        FuturesDescriptor(
            id: "hf_NQ", nameZh: "纳指期货连续", nameEn: "Nasdaq Futures",
            subtitleZh: "CME E-mini · 连续", subtitleEn: "CME E-mini · Continuous",
            source: .sina(symbol: "NQ")
        ),
        FuturesDescriptor(
            id: "hf_NK", nameZh: "日经225期货", nameEn: "Nikkei 225 Futures",
            subtitleZh: "日经225 · 连续", subtitleEn: "Nikkei 225 · Continuous",
            source: .sina(symbol: "NK")
        ),
        FuturesDescriptor(
            id: "hf_OIL", nameZh: "布伦特原油连续", nameEn: "Brent Crude",
            subtitleZh: "ICE · 连续", subtitleEn: "ICE · Continuous",
            source: .sina(symbol: "OIL")
        )
    ]
}

/// 期货报价。涨跌基准是**昨结算价**(新浪字段7),不是昨收(字段8)——
/// 期货涨跌幅的行业标准口径,与东财期货页一致。
struct FuturesQuote: Identifiable, Equatable, Sendable {
    var id: String { descriptor.id }
    let descriptor: FuturesDescriptor
    let price: Decimal
    let prevSettlement: Decimal
    let change: Decimal
    let changePct: Double
}
