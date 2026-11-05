import Foundation

/// 新浪外盘期货实时行情(hq.sinajs.cn,GBK)。
///
/// 请求: `https://hq.sinajs.cn/list=hf_NQ,hf_NK,hf_OIL`
/// 必须带 `Referer: https://finance.sina.com.cn/`,否则返回空。
///
/// 响应示例(GBK,逗号分隔):
///     var hq_str_hf_NQ="28383.690,,28371.500,28372.500,28512.000,27615.750,16:39:04,28305.750,28410.000,0,1,1,2026-11-04,纳斯达克指数期货,0";
///
/// hf_ 字段索引(0-based):
///   - 0: 最新价
///   - 4: 最高
///   - 5: 最低
///   - 6: 时间 (HH:mm:ss)
///   - 7: 昨结算价(涨跌基准!)
///   - 8: 昨收盘价
///   - 12: 日期 (yyyy-MM-dd)
///   - 13: 名称
struct SinaFuturesProvider {
    let id = "sina-futures"

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://finance.sina.com.cn/"])) {
        self.http = http
    }

    /// 批量拉取。只处理 source == .sina 的条目;空入参或无新浪条目时直接返回空。
    func fetchAll(_ descs: [FuturesDescriptor]) async throws -> [FuturesQuote] {
        let sinaDescs = descs.filter {
            if case .sina = $0.source { return true }
            return false
        }
        guard !sinaDescs.isEmpty else { return [] }

        let symbols = sinaDescs.map { desc -> String in
            if case .sina(let sym) = desc.source { return "hf_\(sym)" }
            return ""
        }.filter { !$0.isEmpty }.joined(separator: ",")

        var comps = URLComponents(string: "https://hq.sinajs.cn/")!
        comps.queryItems = [URLQueryItem(name: "list", value: symbols)]
        guard let url = comps.url else { throw ProviderError.empty }

        // 新浪返回 GBK
        let text = try await http.fetchString(url: url, encoding: GBKDecoder.encoding)
        return try parse(text, descs: sinaDescs)
    }

    // MARK: - 解析(纯函数,可测)

    /// 解析新浪批量响应。找不到对应 hq_str_ 行或字段不全的品种被跳过。
    func parse(_ text: String, descs: [FuturesDescriptor]) throws -> [FuturesQuote] {
        // hq_str_ 名 → 字段数组
        var fields: [String: [String]] = [:]
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("var hq_str_"), let eqIdx = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: "var hq_str_".count)..<eqIdx])
            let value = line[line.index(after: eqIdx)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            fields[name] = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }

        var out: [FuturesQuote] = []
        for desc in descs {
            guard case .sina(let sym) = desc.source else { continue }
            guard let f = fields["hf_\(sym)"], f.count > 8 else { continue }
            guard let price = Decimal(string: f[0]), price > 0,
                  let prevSettlement = Decimal(string: f[7]), prevSettlement > 0 else { continue }

            let change = price - prevSettlement
            let pct = Double(truncating: NSDecimalNumber(decimal: change / prevSettlement))
            out.append(FuturesQuote(
                descriptor: desc,
                price: price,
                prevSettlement: prevSettlement,
                change: change,
                changePct: pct
            ))
        }
        return out
    }
}
