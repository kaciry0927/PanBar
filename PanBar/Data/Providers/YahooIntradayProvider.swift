import Foundation

/// Yahoo v8 chart 接口的当日分时兜底源(仅股票,指数不走这里)。
/// interval=5m&range=1d 返回当日 5 分钟级 timestamp + close/volume 序列
/// —— 这正是 YahooProvider(快照)解析时丢弃的数据,这里单独解析。
/// 均价线用累计 Σ(price×volume)/Σ(volume) 近似 VWAP;
/// volume 缺失/为 0 时退化为简单累计平均。
struct YahooIntradayProvider: IntradayProvider {
    let id = "yahoo-intraday"

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetchIntraday(secid: String, cacheKey: String, market: Market?) async throws -> IntradaySeries {
        guard let escaped = secid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ProviderError.empty
        }
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escaped)?interval=5m&range=1d")!
        // 5s:Yahoo 只是兜底,大陆网络下经常黑洞挂死;超时太久会让整条
        // fallback 链(东财失败 → Yahoo 挂 8s → 回东财)拖到十几秒才出结果
        let data = try await http.fetchData(url: url, timeout: 5)
        return try parse(data, cacheKey: cacheKey, market: market)
    }

    // 可测的纯解析函数
    func parse(_ data: Data, cacheKey: String, market: Market?) throws -> IntradaySeries {
        struct Resp: Decodable {
            let chart: Chart
            struct Chart: Decodable {
                let result: [Result]?
            }
            struct Result: Decodable {
                let meta: Meta?
                let timestamp: [Double]?
                let indicators: Indicators?
            }
            struct Meta: Decodable {
                let previousClose: Double?
                let chartPreviousClose: Double?
            }
            struct Indicators: Decodable {
                let quote: [Quote]?
                struct Quote: Decodable {
                    let close: [Double?]?
                    let volume: [Double?]?
                }
            }
        }
        let resp: Resp
        do {
            resp = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw ProviderError.parsing("yahoo-intraday: \(error)")
        }
        guard let r = resp.chart.result?.first,
              let ts = r.timestamp,
              let quote = r.indicators?.quote?.first,
              let closes = quote.close else {
            throw ProviderError.empty
        }
        let vols = quote.volume ?? []

        // 昨收:meta 优先,退化为第一个有效收盘价
        var prevClose = r.meta.flatMap { $0.previousClose ?? $0.chartPreviousClose } ?? 0
        if prevClose <= 0 {
            prevClose = closes.compactMap { $0 }.first ?? 0
        }
        guard prevClose > 0 else { throw ProviderError.empty }

        let tz = market?.timeZone ?? TimeZone(identifier: "America/New_York")!
        let fmt = DateFormatter()
        fmt.timeZone = tz
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"

        var points: [IntradayPoint] = []
        points.reserveCapacity(ts.count)
        var times: [String] = []
        times.reserveCapacity(ts.count)
        var cumPV = 0.0    // 累计 price×volume
        var cumV = 0.0     // 累计 volume
        var sumP = 0.0     // 累计 price(简单平均兜底用)

        for (i, t) in ts.enumerated() {
            guard i < closes.count, let price = closes[i], price > 0 else { continue }
            let v = (i < vols.count ? vols[i] : nil) ?? 0
            if v > 0 {
                cumPV += price * v
                cumV += v
            }
            sumP += price

            let avg = cumV > 0 ? cumPV / cumV : sumP / Double(points.count + 1)
            times.append(fmt.string(from: Date(timeIntervalSince1970: t)))
            points.append(IntradayPoint(seq: points.count, price: price, avgPrice: avg))
        }
        guard !points.isEmpty else { throw ProviderError.empty }

        let labels = EastMoneyIntradayProvider.timeLabels(market: market, firstRowTime: times[0], lastRowTime: times[times.count - 1])
        let layout = EastMoneyIntradayProvider.axisLayout(market: market, times: times, minutesPerSeq: 5)
        return IntradaySeries(
            cacheKey: cacheKey,
            prevClose: prevClose,
            points: points,
            midSeq: layout.midSeq,
            closeSeq: layout.closeSeq,
            openTimeLabel: labels.open,
            midTimeLabel: labels.mid,
            closeTimeLabel: labels.close,
            fetchedAt: Date()
        )
    }
}
