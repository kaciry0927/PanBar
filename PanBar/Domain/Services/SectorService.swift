import Foundation

/// 行业板块涨幅榜 / 跌幅榜。走东财 `clist/get` 行业板块接口(与 IndexService 同源)。
///
/// 接口:`https://push2.eastmoney.com/api/qt/clist/get`
///   - `fs=m:90+t:2` 是行业板块全集(申万一级+二级+三级混排,实测 496 个),
///     同一概念的二级/三级板块会同时上榜(电机Ⅱ/电机Ⅲ、医疗美容/医美耗材)。
///     s 参数过滤层级(实测):s:2/s:3=一级(31),s:4/s:5=二级(128),不带 s=全级混排。
///     这里用 `s:2` = 纯**一级**行业(31 个,宏观视角)。
///   - `fid=f3` 按涨跌幅排序;`po=1` 降序(涨幅榜)、`po=0` 升序(跌幅榜)
///   - 字段:f3=涨跌幅% f12=板块代码 f14=名称 f104=上涨家数 f105=下跌家数
///          f128=领涨股 f140=领涨股代码 f136=领涨股涨跌幅%
actor SectorService {
    /// 纯一级行业(31 个);不带 s 会混入一/二/三级造成同概念重复上榜。
    static let fs = "m:90+t:2+s:2"

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
    }

    /// 一次拿回涨幅榜 + 跌幅榜(各前 n 条)。
    struct Ranking: Sendable {
        let gainers: [SectorBoard]
        let losers: [SectorBoard]
    }

    func fetchRankings(top: Int = 5) async throws -> Ranking {
        async let gainers = fetchTop(top: top, order: 1)  // 涨幅榜:按涨跌幅降序
        async let losers = fetchTop(top: top, order: 0)   // 跌幅榜:按涨跌幅升序
        return try await Ranking(gainers: gainers, losers: losers)
    }

    private func fetchTop(top: Int, order: Int) async throws -> [SectorBoard] {
        var comps = URLComponents(string: "https://push2.eastmoney.com/api/qt/clist/get")!
        comps.queryItems = [
            URLQueryItem(name: "pn", value: "1"),
            URLQueryItem(name: "pz", value: "\(top)"),
            URLQueryItem(name: "po", value: "\(order)"),
            URLQueryItem(name: "np", value: "1"),
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "invt", value: "2"),
            URLQueryItem(name: "fid", value: "f3"),
            URLQueryItem(name: "fs", value: Self.fs),
            URLQueryItem(name: "fields", value: "f3,f12,f14,f104,f105,f128,f136"),
            URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        ]
        guard let url = comps.url else { return [] }
        let data = try await http.fetchData(url: url)
        return try parse(data)
    }

    func parse(_ data: Data) throws -> [SectorBoard] {
        struct Resp: Decodable {
            let data: Block?
            struct Block: Decodable {
                let diff: [Item]?
            }
            struct Item: Decodable {
                let f3: Double?    // 涨跌幅 %
                let f12: String?   // 板块代码
                let f14: String?   // 板块名称
                let f104: Int?     // 上涨家数
                let f105: Int?     // 下跌家数
                let f128: String?  // 领涨股名称
                let f136: Double?  // 领涨股涨跌幅 %
            }
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let items = resp.data?.diff, !items.isEmpty else { return [] }
        return items.compactMap { item in
            guard let code = item.f12, let name = item.f14, !code.isEmpty, !name.isEmpty else { return nil }
            return SectorBoard(
                code: code,
                name: name,
                changePct: item.f3 ?? 0,
                leadingStock: item.f128,
                leadingStockChangePct: item.f136,
                upCount: item.f104 ?? 0,
                downCount: item.f105 ?? 0
            )
        }
    }
}
