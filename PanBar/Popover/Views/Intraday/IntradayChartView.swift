import SwiftUI
import Charts

/// 当日分时图:价格线(涨红跌绿)+ 黄色均价线 + 昨收虚线参考线。
/// x 轴用 IntradayPoint.seq 等距序号(规避 A 股午休时间空洞),域扩展到整日
/// (0...closeSeq),盘中时曲线按比例停在当前时刻。
/// 时间标签是图表内建 x 轴刻度,画在精确的 seq 位置上——与数据坐标系完全对齐。
/// (此前手动画在图下方用 Spacer 均分,受右侧 y 轴占宽影响与曲线错位。)
struct IntradayChartView: View {
    let series: IntradaySeries
    let scheme: TickerColorScheme

    var body: some View {
        Chart {
            ForEach(series.points, id: \.seq) { p in
                // 关键:两条线必须用 foregroundStyle(by:) 拆成独立序列。
                // 同一 ForEach 里不带 by 的两个 LineMark 会被 Charts 拼成一条线
                //(价格线画完直接斜连回均价线起点,整图变成一条乱线)。
                // by 值带数字前缀:range 样式按出现顺序/排序顺序映射结果一致。
                LineMark(x: .value("seq", p.seq), y: .value("price", p.price))
                    .foregroundStyle(by: .value("series", "1price"))
                    .lineStyle(StrokeStyle(lineWidth: 1.2))

                LineMark(x: .value("seq", p.seq), y: .value("avg", p.avgPrice))
                    .foregroundStyle(by: .value("series", "2avg"))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }

            RuleMark(y: .value("prevClose", series.prevClose))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
        // 注:此 SDK(macOS 27)下 domain: [String: Color] 不再满足 ScaleDomain,
        // 只能用 range: 按顺序映射(1price → trendColor,2avg → orange)。
        .chartForegroundStyleScale(range: [trendColor, Color.orange])
        .chartLegend(.hidden)
        .chartXScale(domain: 0...xDomainEnd)
        .chartXAxis {
            AxisMarks(values: xTickSeqs) { value in
                AxisValueLabel {
                    if let seq = value.as(Int.self), let label = xTickLabels[seq] {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .chartYScale(domain: yDomain)
        .frame(height: 126)
    }

    /// 收盘价(最新点)不低于昨收 → 涨色;否则跌色。
    private var trendColor: Color {
        guard let last = series.points.last else { return .secondary }
        return last.price >= series.prevClose
            ? SemanticColors.up(scheme: scheme)
            : SemanticColors.down(scheme: scheme)
    }

    /// x 域终点:整日收盘 seq,且不小于最后一个数据点(防 Provider 数据异常)。
    private var xDomainEnd: Int {
        max(series.closeSeq, series.points.last?.seq ?? 1, 1)
    }

    /// x 轴刻度位置:开盘(0)、午休分界(可选)、收盘(closeSeq)。
    private var xTickSeqs: [Int] {
        [0] + (series.midSeq.map { [$0] } ?? []) + [xDomainEnd]
    }

    /// seq → 时间标签。
    private var xTickLabels: [Int: String] {
        var map: [Int: String] = [
            0: series.openTimeLabel,
            xDomainEnd: series.closeTimeLabel,
        ]
        if let mid = series.midSeq, let midLabel = series.midTimeLabel, mid < xDomainEnd {
            map[mid] = midLabel
        }
        return map
    }

    /// y 轴域覆盖全部点位 + 均价 + 昨收,留一点 padding 保证虚线可见。
    private var yDomain: ClosedRange<Double> {
        let values = series.points.map(\.price) + series.points.map(\.avgPrice)
        var lo = min(values.min() ?? series.prevClose, series.prevClose)
        var hi = max(values.max() ?? series.prevClose, series.prevClose)
        let pad = max((hi - lo) * 0.06, abs(hi) * 0.0005)
        lo -= pad
        hi += pad
        return lo...hi
    }
}
