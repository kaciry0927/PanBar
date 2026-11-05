import Foundation

/// 期货主力连续批量报价。
///
/// 单一数据源:新浪外盘通道(SinaFuturesProvider)。
/// fetchAll 负责:调新浪、按 FuturesCatalog 顺序排序、失败容错
/// (返回空数组由上层决定展示,不向上抛网络错误——与 tickIndices 同策略)。
/// 无缓存——刷新节奏由 QuoteRefresher.runFuturesLoop 控制(15s)。
actor FuturesService {
    private let sina: SinaFuturesProvider

    init(sina: SinaFuturesProvider = SinaFuturesProvider()) {
        self.sina = sina
    }

    func fetchAll(_ descs: [FuturesDescriptor] = FuturesCatalog.all) async throws -> [FuturesQuote] {
        guard !descs.isEmpty else { return [] }
        let quotes = try await sina.fetchAll(descs)

        // 按 FuturesCatalog 顺序排序(与 IndexService 同款)
        let order = Dictionary(uniqueKeysWithValues: descs.enumerated().map { ($0.element.id, $0.offset) })
        return quotes.sorted { (order[$0.descriptor.id] ?? .max) < (order[$1.descriptor.id] ?? .max) }
    }
}
