import XCTest
@testable import PanBar

/// 期货数据解析测试(SinaFuturesProvider.parse / SinaFuturesIntradayProvider.parse)。
///
/// fixture 依据 2026-11-04 实抓响应构造:
///   - 新浪 hf_ 行情为逗号分隔,字段 7 是**昨结算**(涨跌基准,≠字段 8 昨收);
///   - getMinK 返回 JSONP 壳 + 多日 5 分钟线,需剥壳并取最后一个连续段。
final class FuturesParsingTests: XCTestCase {
    private let sina = SinaFuturesProvider()
    private let sinaIntraday = SinaFuturesIntradayProvider()

    // MARK: - SinaFuturesProvider.parse

    private func sinaDesc(_ id: String, symbol: String) -> FuturesDescriptor {
        FuturesDescriptor(
            id: id, nameZh: id, nameEn: id,
            subtitleZh: "", subtitleEn: "",
            source: .sina(symbol: symbol)
        )
    }

    func testSinaQuoteParsesAgainstPrevSettlement() throws {
        // 2026-11-04 实抓 hf_NQ 响应(GBK 已转 UTF-8)
        let text = #"var hq_str_hf_NQ="28383.690,,28371.500,28372.500,28512.000,27615.750,16:39:04,28305.750,28410.000,0,1,1,2026-11-04,纳斯达克指数期货,0";"#
        let quotes = try sina.parse(text, descs: [sinaDesc("hf_NQ", symbol: "NQ")])
        XCTAssertEqual(quotes.count, 1)
        let q = quotes[0]
        XCTAssertEqual(q.price, Decimal(string: "28383.690"))
        XCTAssertEqual(q.prevSettlement, Decimal(string: "28305.750"))
        // 涨跌基准 = 昨结算(字段7),不是昨收(字段8)
        XCTAssertEqual(q.change, Decimal(string: "77.940"))
        XCTAssertEqual(q.changePct, 77.94 / 28305.75, accuracy: 1e-9)
    }

    func testSinaQuoteSkipsMissingOrInvalidLines() throws {
        // hf_NK 缺失、hf_OIL prevSettlement=0(字段7) → 两者都跳过
        let text = [
            #"var hq_str_hf_OIL="104.033,,103.910,103.940,104.960,102.560,16:39:02,0,104.230,0,3,4,2026-11-04,布伦特原油,0";"#
        ].joined(separator: "\n")
        let quotes = try sina.parse(text, descs: [sinaDesc("hf_NK", symbol: "NK"), sinaDesc("hf_OIL", symbol: "OIL")])
        XCTAssertTrue(quotes.isEmpty)
    }

    func testSinaQuoteEmptyResponseYieldsNothing() throws {
        let text = #"var hq_str_hf_XXX="";"#
        let quotes = try sina.parse(text, descs: [sinaDesc("hf_NQ", symbol: "NQ")])
        XCTAssertTrue(quotes.isEmpty)
    }

    // MARK: - SinaFuturesIntradayProvider.parse

    private func jsonpRow(_ d: String, _ c: Double) -> String {
        String(format: #"{"d":"%@","o":"%.3f","h":"%.3f","l":"%.3f","c":"%.3f","v":"100","p":"0"}"#, d, c, c + 1, c - 1, c)
    }

    func testIntradayStripsJSONPAndTakesLastSegment() throws {
        // 两段数据:前段(旧)与后段(最新),间隔 10 小时 → 只取后段
        var rows: [String] = []
        rows.append(jsonpRow("2026-11-03 17:05:00", 64000))
        rows.append(jsonpRow("2026-11-03 17:10:00", 64010))
        rows.append(jsonpRow("2026-11-04 15:05:00", 62900))   // 与上行间隔 > 1h,切段
        rows.append(jsonpRow("2026-11-04 15:10:00", 62910))
        rows.append(jsonpRow("2026-11-04 15:15:00", 62920))
        let text = "/*<script>location.href='//sina.com';</script>*/\nvar t=([" + rows.joined(separator: ",") + "]);"

        let s = try sinaIntraday.parse(text, cacheKey: "hf_NK")
        XCTAssertEqual(s.cacheKey, "hf_NK")
        XCTAssertEqual(s.points.count, 3)
        XCTAssertEqual(s.points[0].price, 62900, accuracy: 0.001)
        XCTAssertEqual(s.points[2].seq, 2)
        // provider 只能用段首 open 占位 prevClose,调用侧会用昨结算校正
        XCTAssertEqual(s.prevClose, 62900, accuracy: 0.001)
        // market=nil 兜底:标签取数据首末行时间
        XCTAssertEqual(s.openTimeLabel, "15:05")
        XCTAssertEqual(s.closeTimeLabel, "15:15")
    }

    func testIntradayRejectsMalformedShell() {
        XCTAssertThrowsError(try sinaIntraday.parse("no jsonp here", cacheKey: "x"))
    }

    func testIntradayRejectsSingleRow() throws {
        // 只有一行数据 → 无法构成序列
        let text = "var t=([" + jsonpRow("2026-11-04 15:05:00", 100) + "]);"
        XCTAssertThrowsError(try sinaIntraday.parse(text, cacheKey: "x"))
    }

    // MARK: - Catalog 不变量

    /// 期货 catalog 的 id 不得与指数 catalog 重合(共用 IntradayStore cacheKey 空间,
    /// 重合会导致分时缓存/展开状态跨 tab 串扰)。
    func testCatalogIDsDoNotClashWithIndexCatalog() {
        let indexIDs = Set(IndexCatalog.all.map(\.id))
        for f in FuturesCatalog.all {
            XCTAssertFalse(indexIDs.contains(f.id), "Futures id '\(f.id)' clashes with IndexCatalog")
        }
        XCTAssertEqual(FuturesCatalog.all.count, 3)
        // KOSPI 现货顶替已移除:不允许再出现东财 source
        for f in FuturesCatalog.all {
            guard case .sina = f.source else {
                return XCTFail("FuturesCatalog entries must use sina source, got \(f.id)")
            }
        }
    }
}
