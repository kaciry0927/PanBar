import XCTest
@testable import PanBar

/// 分时数据解析器测试(EastMoneyIntradayProvider.parse / YahooIntradayProvider.parse)。
///
/// fixture 依据 2026-10-20 实抓响应构造:
///   - trends2 的 data 块仅在 fields1 给全 f1~f13 时才带 preClose(曾因此丢字段);
///   - 部分指数(如恒指)首点 f58 均价为 0,必须沿用上一有效均价,不能用 累计额/累计量
///     兜底(指数量额比无 VWAP 语义,会算出荒谬值)。
final class IntradayParsingTests: XCTestCase {
    private let east = EastMoneyIntradayProvider()
    private let yahoo = YahooIntradayProvider()

    // MARK: - EastMoney trends2

    private func eastJSON(preClose: Double?, trends: [String]) -> Data {
        var block: [String: Any] = [
            "code": "600519", "market": 1, "name": "贵州茅台", "decimal": 2
        ]
        if let preClose { block["preClose"] = preClose }
        block["trends"] = trends
        return try! JSONSerialization.data(withJSONObject: ["data": block])
    }

    func testEastMoneyParsesPointsAndLabels() throws {
        let data = eastJSON(
            preClose: 1324.97,
            trends: [
                "2026-10-20 09:30,1321.01,1321.01,1321.01,1321.01,154,20376579.00,1321.010",
                "2026-10-20 09:31,1322.00,1323.50,1324.00,1321.50,200,26470000.00,1322.250",
                "2026-10-20 09:32,1323.00,1322.10,1323.80,1322.00,100,13220000.00,1322.200"
            ]
        )
        let s = try east.parse(data, cacheKey: "a_600519", market: .a)
        XCTAssertEqual(s.cacheKey, "a_600519")
        XCTAssertEqual(s.prevClose, 1324.97, accuracy: 0.001)
        XCTAssertEqual(s.points.count, 3)
        XCTAssertEqual(s.points[0].seq, 0)
        XCTAssertEqual(s.points[2].seq, 2)
        XCTAssertEqual(s.points[1].price, 1323.50, accuracy: 0.001)
        XCTAssertEqual(s.points[1].avgPrice, 1322.25, accuracy: 0.001)
        // A 股时间标签固定 + 午休标注
        XCTAssertEqual(s.openTimeLabel, "09:30")
        XCTAssertEqual(s.midTimeLabel, "11:30/13:00")
        XCTAssertEqual(s.closeTimeLabel, "15:00")
    }

    /// 恒指首点 f58=0:沿用上一有效均价(首个点退化为现价),不允许出现量额比。
    func testEastMoneyZeroAvgCarriesForward() throws {
        let data = eastJSON(
            preClose: 24010.0,
            trends: [
                "2026-10-20 09:30,23990.05,23990.05,23990.05,23990.05,227610992,6201082368.00,0.000",
                "2026-10-20 09:31,23980.00,23985.00,23988.00,23970.00,100000000,2300000000.00,23988.500",
                "2026-10-20 09:32,23960.00,23982.32,23984.19,23956.65,38071837,571371520.00,0.000"
            ]
        )
        let s = try east.parse(data, cacheKey: "HSI", market: .hk)
        // 首点 f58 无效 → 现价
        XCTAssertEqual(s.points[0].avgPrice, 23990.05, accuracy: 0.001)
        // 次点 f58 有效
        XCTAssertEqual(s.points[1].avgPrice, 23988.5, accuracy: 0.001)
        // 末点 f58 又为 0 → 沿用次点的有效均价(而不是量额比 2300000000/100000000=23)
        XCTAssertEqual(s.points[2].avgPrice, 23988.5, accuracy: 0.001)
    }

    /// preClose 缺失(旧行为:f1~f6 fields1 下响应无该字段)必须报错而不是产出错误昨收。
    func testEastMoneyMissingPreCloseThrows() {
        let data = eastJSON(
            preClose: nil,
            trends: ["2026-10-20 09:30,1321.01,1321.01,1321.01,1321.01,154,20376579.00,1321.010"]
        )
        XCTAssertThrowsError(try east.parse(data, cacheKey: "a_600519", market: .a))
    }

    func testEastMoneyEmptyTrendsThrows() {
        let data = eastJSON(preClose: 1324.97, trends: [])
        XCTAssertThrowsError(try east.parse(data, cacheKey: "a_600519", market: .a))
    }

    /// 无午休市场/全球指数的时间标签分支。
    func testEastMoneyTimeLabelsByMarket() {
        let us = EastMoneyIntradayProvider.timeLabels(market: .us, firstRowTime: "21:30", lastRowTime: "04:00")
        XCTAssertEqual(us.open, "09:30")
        XCTAssertNil(us.mid)
        XCTAssertEqual(us.close, "16:00")

        let hk = EastMoneyIntradayProvider.timeLabels(market: .hk, firstRowTime: "09:30", lastRowTime: "16:00")
        XCTAssertEqual(hk.mid, "12:00/13:00")
        XCTAssertEqual(hk.close, "16:00")

        // 全球指数(market=nil)用数据首末行时间兜底
        let nilM = EastMoneyIntradayProvider.timeLabels(market: nil, firstRowTime: "09:00", lastRowTime: "15:30")
        XCTAssertEqual(nilM.open, "09:00")
        XCTAssertNil(nilM.mid)
        XCTAssertEqual(nilM.close, "15:30")
    }

    // MARK: - Yahoo chart

    private func yahooJSON(timestamps: [Double], closes: [Double?], vols: [Double?], prevClose: Double?) -> Data {
        var quote: [String: Any] = ["close": closes]
        if vols.isEmpty == false { quote["volume"] = vols }
        var meta: [String: Any] = [:]
        if let prevClose { meta["chartPreviousClose"] = prevClose }
        let body: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": meta,
                    "timestamp": timestamps,
                    "indicators": ["quote": [quote]]
                ]]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testYahooParsesVWAPAndLabels() throws {
        // 5 分钟级 4 个点,量不等:VWAP 应为 Σ(p·v)/Σ(v)
        let data = yahooJSON(
            timestamps: [1_760_000_000, 1_760_030_000, 1_760_060_000, 1_760_090_000],
            closes: [100.0, 101.0, 102.0, 103.0],
            vols: [1000.0, 1000.0, 1000.0, 1000.0],
            prevClose: 99.0
        )
        let s = try yahoo.parse(data, cacheKey: "us_AAPL", market: .us)
        XCTAssertEqual(s.prevClose, 99.0, accuracy: 0.001)
        XCTAssertEqual(s.points.count, 4)
        XCTAssertEqual(s.points[0].seq, 0)
        // 等量 → VWAP = 简单平均
        XCTAssertEqual(s.points[3].avgPrice, 101.5, accuracy: 0.001)
        // 美股:无午休标注
        XCTAssertNil(s.midTimeLabel)
        XCTAssertEqual(s.openTimeLabel, "09:30")
        XCTAssertEqual(s.closeTimeLabel, "16:00")
    }

    /// volume 全缺失:退化为简单累计平均,且不崩溃。
    func testYahooDegeneratesToSimpleAverageWithoutVolume() throws {
        let data = yahooJSON(
            timestamps: [1_760_000_000, 1_760_030_000, 1_760_060_000],
            closes: [10.0, 20.0, 30.0],
            vols: [],
            prevClose: 9.0
        )
        let s = try yahoo.parse(data, cacheKey: "us_TSLA", market: .us)
        XCTAssertEqual(s.points[2].avgPrice, 20.0, accuracy: 0.001)
    }

    /// close 数组中有 nil(Yahoo 常见):跳过该点,seq 仍连续。
    func testYahooSkipsNilCloses() throws {
        let data = yahooJSON(
            timestamps: [1_760_000_000, 1_760_030_000, 1_760_060_000],
            closes: [10.0, nil, 12.0],
            vols: [1.0, 1.0, 1.0],
            prevClose: 10.0
        )
        let s = try yahoo.parse(data, cacheKey: "us_NVDA", market: .us)
        XCTAssertEqual(s.points.count, 2)
        XCTAssertEqual(s.points[0].price, 10.0, accuracy: 0.001)
        XCTAssertEqual(s.points[1].seq, 1)
        XCTAssertEqual(s.points[1].price, 12.0, accuracy: 0.001)
    }

    // MARK: - x 轴布局(整日域扩展,时间标签与数据坐标系对齐的关键)

    /// A 股盘中(09:32):13:00 应在 seq 121,收盘应在 seq 241,
    /// 曲线按比例停在开头(2/241),而不是被拉伸到右缘。
    func testAxisLayoutAMidSession() {
        let l = EastMoneyIntradayProvider.axisLayout(
            market: .a, times: ["09:30", "09:31", "09:32"], minutesPerSeq: 1
        )
        XCTAssertEqual(l.midSeq, 121)
        XCTAssertEqual(l.closeSeq, 241)
    }

    /// A 股午后:13:00 行的实际序号作为午休分界。
    func testAxisLayoutAAfterLunch() {
        let l = EastMoneyIntradayProvider.axisLayout(
            market: .a, times: ["09:30", "11:30", "13:00", "13:02"], minutesPerSeq: 1
        )
        XCTAssertEqual(l.midSeq, 2)
        XCTAssertEqual(l.closeSeq, 241)
    }

    /// 港股(09:30-12:00 / 13:00-16:00)与美股(390 分钟,步长 5 → 78)。
    func testAxisLayoutHKAndUS() {
        let hk = EastMoneyIntradayProvider.axisLayout(
            market: .hk, times: ["09:30", "09:31"], minutesPerSeq: 1
        )
        XCTAssertEqual(hk.midSeq, 151)   // 上午 150 分钟 + 1
        XCTAssertEqual(hk.closeSeq, 331) // 150 + 1 + 180

        let us = EastMoneyIntradayProvider.axisLayout(
            market: .us, times: ["21:30", "21:35"], minutesPerSeq: 1
        )
        XCTAssertNil(us.midSeq)
        XCTAssertEqual(us.closeSeq, 390) // 东财给北京时间也恒为 390 行步

        let us5m = EastMoneyIntradayProvider.axisLayout(
            market: .us, times: ["09:30", "09:35"], minutesPerSeq: 5
        )
        XCTAssertEqual(us5m.closeSeq, 78)
    }

    /// 全球指数无统一时段:域取数据本身(mid 为 nil,close == lastSeq)。
    func testAxisLayoutNilMarket() {
        let l = EastMoneyIntradayProvider.axisLayout(
            market: nil, times: ["09:00", "12:00", "15:30"], minutesPerSeq: 1
        )
        XCTAssertNil(l.midSeq)
        XCTAssertEqual(l.closeSeq, 2)
    }
}
