import Foundation

/// 新浪外盘期货分时(gu.sina.cn,5 分钟线,JSONP)。
///
/// 请求: `https://gu.sina.cn/ft/api/jsonp.php/var%20t=/GlobalService.getMinK?symbol=NQ&type=5`
/// 必须带 `Referer: https://finance.sina.com.cn/`。响应 UTF-8,形如:
///
///     /*<script>location.href='//sina.com';</script>*/
///     var t=([{"d":"2026-11-03 17:05:00","o":"64684.000","h":"64747.700","l":"64679.500","c":"64693.000","v":"207","p":"44044"},...]);
///
/// 字段: d=时间(yyyy-MM-dd HH:mm:ss 北京时间) o/h/l/c=开高低收 v=成交量 p=持仓量。
/// 注意:不含昨结算 → series.prevClose 先用段首 open 占位,由调用侧(FuturesTab)
/// 用 FuturesQuote.prevSettlement 校正(参考线与涨跌配色基准)。
///
/// 返回含多日数据。外盘期货"当日"时段不规则(纳指/布油近全天候、日经夜盘+日盘),
/// 取**最后一个连续段**(相邻行间隔 > 60 分钟即断)作为分时序列。
struct SinaFuturesIntradayProvider: IntradayProvider {
    let id = "sina-futures-intraday"

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://finance.sina.com.cn/"])) {
        self.http = http
    }

    /// 分钟线步长(type=5 → 5 分钟)。
    static let minutesPerSeq = 5

    func fetchIntraday(secid: String, cacheKey: String, market: Market?) async throws -> IntradaySeries {
        var comps = URLComponents(string: "https://gu.sina.cn/ft/api/jsonp.php/var%20t=/GlobalService.getMinK")!
        comps.queryItems = [
            URLQueryItem(name: "symbol", value: secid),
            URLQueryItem(name: "type", value: "5")
        ]
        guard let url = comps.url else { throw ProviderError.empty }
        let text = try await http.fetchString(url: url)
        return try parse(text, cacheKey: cacheKey)
    }

    // MARK: - 解析(纯函数,可测)

    func parse(_ text: String, cacheKey: String) throws -> IntradaySeries {
        // 1. 剥 JSONP 壳:取首个 "(" 与末个 ")" 之间的 JSON
        guard let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"),
              start < end else { throw ProviderError.parsing("sina-futures-intraday: JSONP shell not found") }
        let json = String(text[text.index(after: start)..<end])

        struct Row: Decodable {
            let d: String   // "2026-11-04 15:30:00"
            let o: String
            let c: String
            let v: String
        }
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        } catch {
            throw ProviderError.parsing("sina-futures-intraday: \(error)")
        }
        guard rows.count >= 2 else { throw ProviderError.empty }

        // 2. 时间解析(新浪给北京时间)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let parsed: [(date: Date, time: String, price: Double)] = rows.compactMap { row in
            guard let price = Double(row.c), price > 0,
                  let date = fmt.date(from: row.d) else { return nil }
            let time = String(row.d.suffix(8).prefix(5))   // "HH:mm"
            return (date, time, price)
        }
        guard parsed.count >= 2 else { throw ProviderError.empty }

        // 3. 切段:从尾部往前,相邻间隔 > 60 分钟即断,取最后连续段
        let segment = Self.lastContinuousSegment(of: parsed, maxGapSeconds: 3600)
        guard segment.count >= 2 else { throw ProviderError.empty }

        // 4. 组装 points;无均价数据(VWAP 不可得),avgPrice 退化为 price(均价线与价格线重合)
        var points: [IntradayPoint] = []
        points.reserveCapacity(segment.count)
        for row in segment {
            points.append(IntradayPoint(seq: points.count, price: row.price, avgPrice: row.price))
        }

        // 5. 轴布局与时间标签复用东财 provider 的 market=nil 兜底(数据自描述)
        let times = segment.map { $0.time }
        let layout = EastMoneyIntradayProvider.axisLayout(market: nil, times: times, minutesPerSeq: Self.minutesPerSeq)
        let labels = EastMoneyIntradayProvider.timeLabels(market: nil, firstRowTime: times[0], lastRowTime: times[times.count - 1])

        return IntradaySeries(
            cacheKey: cacheKey,
            prevClose: segment[0].price,   // 占位:调用侧用昨结算校正
            points: points,
            midSeq: layout.midSeq,
            closeSeq: layout.closeSeq,
            openTimeLabel: labels.open,
            midTimeLabel: labels.mid,
            closeTimeLabel: labels.close,
            fetchedAt: Date()
        )
    }

    /// 从尾部往前找最后一个"相邻间隔 ≤ maxGapSeconds"的连续段。
    static func lastContinuousSegment(of rows: [(date: Date, time: String, price: Double)], maxGapSeconds: TimeInterval) -> [(date: Date, time: String, price: Double)] {
        guard !rows.isEmpty else { return [] }
        var start = rows.count - 1
        while start > 0 {
            let gap = rows[start].date.timeIntervalSince(rows[start - 1].date)
            if gap > maxGapSeconds || gap < 0 { break }   // 负间隔(乱序)也切断,保守取尾部
            start -= 1
        }
        return Array(rows[start...])
    }
}
