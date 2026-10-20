import Foundation

/// 当日分时数据源协议。
/// 与 QuoteProvider(批量快照)分开定义:分时是单标的请求,批量语义不匹配;
/// fallback 链也更短(指数只有东财一条路),不值得塞进 ProviderOrchestrator
/// 的市场级偏好 / cooldown 机制,由 IntradayService 自行编排。
protocol IntradayProvider: Sendable {
    var id: String { get }
    /// - Parameters:
    ///   - secid: 数据源侧的标的编码(东财 "1.600519" / Yahoo "600519.SS")
    ///   - cacheKey: 透传给 IntradaySeries.cacheKey
    ///   - market: 用于决定时间轴标签(开/收/午休);全球指数可能传 nil
    func fetchIntraday(secid: String, cacheKey: String, market: Market?) async throws -> IntradaySeries
}
