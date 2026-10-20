import Foundation

/// 东方财富 push2his.eastmoney.com 当日分时接口(主数据源,大陆网络稳定)。
/// trends2/get 返回当日分钟级序列,A 股 / 港股 / 美股 / 指数(含全球指数)都支持。
///
/// fields2 字段: f51=时间 f52=开 f53=现价 f54=高 f55=低 f56=量 f57=额 f58=均价
struct EastMoneyIntradayProvider: IntradayProvider {
    let id = "eastmoney-intraday"

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
    }

    func fetchIntraday(secid: String, cacheKey: String, market: Market?) async throws -> IntradaySeries {
        var comps = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/trends2/get")!
        comps.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            // fields1 必须给全 f1~f13,响应里才会带 preClose(实测 f1~f6 时缺失)
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58"),
            URLQueryItem(name: "iscr", value: "0"),
            URLQueryItem(name: "ndays", value: "1"),
            // 防缓存,与 EastMoneyProvider / IndexService 一致
            URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        ]
        guard let url = comps.url else { throw ProviderError.empty }
        let data = try await http.fetchData(url: url)
        return try parse(data, cacheKey: cacheKey, market: market)
    }

    // 可测的纯解析函数
    func parse(_ data: Data, cacheKey: String, market: Market?) throws -> IntradaySeries {
        struct Resp: Decodable {
            let data: Block?
            struct Block: Decodable {
                let name: String?
                let preClose: Double?
                /// 每行 CSV:"2026-10-20 09:30,开,现价,高,低,量,额,均价"
                let trends: [String]?
            }
        }
        let resp: Resp
        do {
            resp = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw ProviderError.parsing("eastmoney-intraday: \(error)")
        }
        guard let preClose = resp.data?.preClose, preClose > 0,
              let trends = resp.data?.trends, !trends.isEmpty else {
            throw ProviderError.empty
        }

        var points: [IntradayPoint] = []
        points.reserveCapacity(trends.count)
        var times: [String] = []
        times.reserveCapacity(trends.count)
        var prevAvg: Double?

        for row in trends {
            let cols = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 8, let price = Double(cols[2]), price > 0 else { continue }

            // 均价优先用 f58;缺失/为 0(部分指数首点)时沿用上一个有效均价。
            // 注意不能用 累计额/累计量 兜底:指数的量额比没有价量 VWAP 语义,会算出荒谬值。
            let f58 = Double(cols[7])
            if let f58, f58 > 0 { prevAvg = f58 }
            let avg = prevAvg ?? price

            times.append(String(cols[0].suffix(5)))   // "2026-10-20 09:30" → "09:30"
            points.append(IntradayPoint(seq: points.count, price: price, avgPrice: avg))
        }
        guard !points.isEmpty else { throw ProviderError.empty }

        let labels = Self.timeLabels(market: market, firstRowTime: times[0], lastRowTime: times[times.count - 1])
        let layout = Self.axisLayout(market: market, times: times, minutesPerSeq: 1)
        return IntradaySeries(
            cacheKey: cacheKey,
            prevClose: preClose,
            points: points,
            midSeq: layout.midSeq,
            closeSeq: layout.closeSeq,
            openTimeLabel: labels.open,
            midTimeLabel: labels.mid,
            closeTimeLabel: labels.close,
            fetchedAt: Date()
        )
    }

    /// 时间轴标签:已知市场用固定值(与 MarketClock 的时段定义一致);
    /// 全球指数(market == nil)没有统一定义,用数据首末行时间兜底。
    static func timeLabels(market: Market?, firstRowTime: String, lastRowTime: String)
        -> (open: String, mid: String?, close: String) {
        switch market {
        case .a:  return ("09:30", "11:30/13:00", "15:00")
        case .hk: return ("09:30", "12:00/13:00", "16:00")
        case .us: return ("09:30", nil, "16:00")
        case nil: return (firstRowTime, nil, lastRowTime)
        }
    }

    // MARK: - x 轴布局(整日域扩展)

    /// 计算午休分界 seq 与收盘 seq,把 x 轴域扩展到整日(0...closeSeq):
    /// 盘中时曲线按比例停在当前时刻,时间标签永远与数据坐标系对齐。
    ///
    /// 行空间与交易分钟的关系:午休不产生行,但 13:00 是 11:30 之后的下一行,
    /// 所以收盘 seq = 上午分钟数/步长 + 1 + 午后分钟数/步长。
    /// - minutesPerSeq: 每行代表的分钟数(东财分钟线=1,Yahoo 5 分钟线=5)
    static func axisLayout(market: Market?, times: [String], minutesPerSeq: Int)
        -> (midSeq: Int?, closeSeq: Int) {
        let lastSeq = max(times.count - 1, 0)
        switch market {
        case .a:
            return lunchLayout(times: times, lastSeq: lastSeq, lunchStart: "11:30",
                               afternoonOpen: "13:00", morningMinutes: 120,
                               afternoonMinutes: 120, minutesPerSeq: minutesPerSeq)
        case .hk:
            return lunchLayout(times: times, lastSeq: lastSeq, lunchStart: "12:00",
                               afternoonOpen: "13:00", morningMinutes: 150,
                               afternoonMinutes: 180, minutesPerSeq: minutesPerSeq)
        case .us:
            // 美股无午休,常规时段恒为 390 分钟(东财给北京时间、Yahoo 给美东时间,
            // 但首行都对应开盘,行空间与墙钟无关,夏令时也不影响)。
            return (nil, 390 / minutesPerSeq)
        case nil:
            // 全球指数无统一时段定义:域就取数据本身,标签用数据首末时间,天然对齐
            return (nil, lastSeq)
        }
    }

    /// 有午休市场(A/HK)的轴布局。
    private static func lunchLayout(times: [String], lastSeq: Int, lunchStart: String,
                                    afternoonOpen: String, morningMinutes: Int,
                                    afternoonMinutes: Int, minutesPerSeq: Int)
        -> (midSeq: Int?, closeSeq: Int) {
        guard let last = times.last else { return (nil, lastSeq) }
        let closeSeq = morningMinutes / minutesPerSeq + 1 + afternoonMinutes / minutesPerSeq

        let midSeq: Int?
        if let idx = times.firstIndex(of: afternoonOpen) {
            // 数据已进行到午后:13:00 行的实际序号就是分界
            midSeq = idx
        } else if last <= lunchStart {
            // 还在上午:13:00 是午休开始(lunchStart)之后的下一行,午休不产生行
            midSeq = lastSeq + minutesBetween(last, lunchStart) / minutesPerSeq + 1
        } else {
            midSeq = nil
        }
        return (midSeq, closeSeq)
    }

    /// "HH:MM" → to - from 的当日分钟差(同日,不跨午夜)。
    static func minutesBetween(_ from: String, _ to: String) -> Int {
        let f = from.split(separator: ":").compactMap { Int($0) }
        let t = to.split(separator: ":").compactMap { Int($0) }
        guard f.count == 2, t.count == 2 else { return 0 }
        return (t[0] * 60 + t[1]) - (f[0] * 60 + f[1])
    }
}
