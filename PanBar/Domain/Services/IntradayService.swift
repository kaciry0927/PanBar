import Foundation

/// 当日分时数据编排:东财主源 + Yahoo 兜底(仅股票),带 30s 内存缓存。
///
/// 缓存不落盘:单只全量分时约 240~390 点 ≈ 20KB,内存缓存零成本;
/// QuoteCacheRepository 明确不缓存 OHLC,落盘还要处理跨交易日失效,收益极低。
actor IntradayService {
    static let cacheTTL: TimeInterval = 30
    /// 东财失败后的冷却时间:期间 Yahoo 优先,但东财仍作兜底重试(见 fetchFresh)。
    /// 实测教训:东财偶发 412 反爬,若冷却期彻底屏蔽东财,叠加 Yahoo 在大陆不可用,
    /// 一次瞬态失败会让错误卡满整个冷却期(曾设 300s,过长)。
    static let emCooldown: TimeInterval = 60

    private let east: EastMoneyIntradayProvider
    private let yahoo: YahooIntradayProvider

    private var cache: [String: (series: IntradaySeries, at: Date)] = [:]
    /// key: IntradayTarget.cacheKey → 冷却截止时间
    private var emCooldownUntil: [String: Date] = [:]

    init(east: EastMoneyIntradayProvider = EastMoneyIntradayProvider(),
         yahoo: YahooIntradayProvider = YahooIntradayProvider()) {
        self.east = east
        self.yahoo = yahoo
    }

    func fetch(_ target: IntradayTarget) async throws -> IntradaySeries {
        let key = target.cacheKey
        if let c = cache[key], Date().timeIntervalSince(c.at) < Self.cacheTTL {
            return c.series
        }
        let series = try await fetchFresh(target)
        cache[key] = (series, Date())
        return series
    }

    private func fetchFresh(_ target: IntradayTarget) async throws -> IntradaySeries {
        switch target {
        case .index(let d):
            // 指数只有东财一条路(emSecid 覆盖含全球指数的全部 11 个)
            return try await eastWithRetry(secid: d.emSecid, cacheKey: d.id, market: d.market)

        case .sector(let b):
            // 行业板块:东财 trends2 支持板块 secid(90.BKxxxx),只有东财一条路
            return try await eastWithRetry(secid: "90.\(b.code)", cacheKey: b.code, market: .a)

        case .stock(let s):
            let key = target.cacheKey
            // 冷却期 ≠ 屏蔽东财,只是把 Yahoo 提到前面:东财偶发 412/限流是瞬态的,
            // 每次都仍要兜底重试东财,否则一次失败会卡到冷却结束才有机会恢复。
            let yahooFirst = emCooldownUntil[key] != nil

            if yahooFirst, let series = try? await yahooForStock(s) {
                emCooldownUntil[key] = nil
                return series
            }
            // 东财:美股 secid 的交易所前缀难精确判定(105=NASDAQ/106=NYSE),依次重试
            for secid in eastSecids(s) {
                if let secid,
                   let series = try? await eastWithRetry(secid: secid, cacheKey: key, market: s.market) {
                    emCooldownUntil[key] = nil
                    return series
                }
            }
            // 最后 Yahoo(冷却期内已在前面试过则不重复)
            if !yahooFirst, let series = try? await yahooForStock(s) {
                emCooldownUntil[key] = Date().addingTimeInterval(Self.emCooldown)
                return series
            }
            emCooldownUntil[key] = Date().addingTimeInterval(Self.emCooldown)
            throw ProviderError.empty
        }
    }

    /// 东财单次请求有 ~20-30% 概率瞬态断连(实测 RemoteDisconnected,换连接即恢复),
    /// 所以同一次 fetch 内立即重试一次:成功率 0.75 → ~0.94,不用等 30s 轮询。
    /// 只重试传输类错误;解析错误是确定性的,重试没有意义。
    private func eastWithRetry(secid: String, cacheKey: String, market: Market?) async throws -> IntradaySeries {
        do {
            return try await east.fetchIntraday(secid: secid, cacheKey: cacheKey, market: market)
        } catch let e as ProviderError {
            if case .parsing = e { throw e }
            try? await Task.sleep(nanoseconds: 400_000_000)
            return try await east.fetchIntraday(secid: secid, cacheKey: cacheKey, market: market)
        } catch {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return try await east.fetchIntraday(secid: secid, cacheKey: cacheKey, market: market)
        }
    }

    /// 东财侧编码候选:.us 依次尝试 NASDAQ / NYSE;其余市场单一候选。
    private func eastSecids(_ s: SymbolID) -> [String?] {
        switch s.market {
        case .us:
            let code = s.code.uppercased()
            return ["105.\(code)", "106.\(code)"]
        default:
            return [SymbolEncoder.eastMoney(s)]
        }
    }

    private func yahooForStock(_ s: SymbolID) async throws -> IntradaySeries {
        guard let code = SymbolEncoder.yahoo(s) else { throw ProviderError.unsupportedMarket(s.market) }
        return try await yahoo.fetchIntraday(secid: code, cacheKey: s.storageKey, market: s.market)
    }
}
