import SwiftUI

/// 期货 Tab:3 个主力连续(新浪 hf_NQ/hf_NK/hf_OIL)。
/// 结构与 IndicesTab 同构:行(名称+价格+涨跌) + 点击展开分时 + 底部隐藏恢复区。
struct FuturesTab: View {
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences
    @EnvironmentObject var intraday: IntradayStore

    /// 已隐藏品种管理区是否展开。
    @State private var showHiddenSection = false

    /// 期货 Tab 显示的品种 = 全量 - 用户隐藏的。
    private var visibleQuotes: [FuturesQuote] {
        refresher.futuresQuotes.filter { !prefs.popoverHiddenFuturesIDs.contains($0.id) }
    }
    private var hiddenQuotes: [FuturesQuote] {
        refresher.futuresQuotes.filter { prefs.popoverHiddenFuturesIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if refresher.futuresQuotes.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleQuotes) { q in
                        Button {
                            toggleIntraday(.futures(q.descriptor))
                        } label: {
                            FuturesRow(quote: q, scheme: prefs.colorScheme, priceFractionDigits: prefs.priceFractionDigits, isExpanded: intraday.expandedKey == q.id)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("futures.hide", comment: "")) {
                                withAnimation {
                                    _ = prefs.popoverHiddenFuturesIDs.insert(q.id)
                                }
                            }
                        }
                        if intraday.expandedKey == q.id {
                            IntradaySectionView(
                                target: .futures(q.descriptor),
                                key: q.id,
                                scheme: prefs.colorScheme,
                                // 新浪分时不带昨结算(provider 用段首 open 占位),
                                // 用行情行的昨结算校正参考线与涨跌配色基准。
                                prevCloseOverride: settlementOverride(for: q)
                            )
                        }
                        Divider().opacity(0.4)
                    }
                    if !hiddenQuotes.isEmpty {
                        hiddenSection
                    }
                }
            }
        }
        .thinScrollbar()
        .frame(maxHeight: 320)
        .onAppear {
            // tab 首次进入抢答一次(refreshLoop 15s 间隔太慢)
            refresher.refreshFuturesNow()
        }
    }

    /// 该品种的昨结算(Double,供分时参考线);无行情数据时返回 nil(用占位值)。
    private func settlementOverride(for quote: FuturesQuote) -> Double? {
        guard quote.prevSettlement > 0 else { return nil }
        return Double(truncating: NSDecimalNumber(decimal: quote.prevSettlement))
    }

    /// 底部"已隐藏品种"折叠区:可逐个恢复,也可一键全部恢复。
    private var hiddenSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { showHiddenSection.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                    Text(String(format: L("futures.hiddenCount", comment: ""), hiddenQuotes.count))
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: showHiddenSection ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHiddenSection {
                ForEach(hiddenQuotes) { q in
                    HStack {
                        Text(q.descriptor.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            withAnimation {
                                _ = prefs.popoverHiddenFuturesIDs.remove(q.id)
                            }
                        } label: {
                            Label(L("futures.hidden.show", comment: ""), systemImage: "eye")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    Divider().opacity(0.25)
                }
                Button {
                    withAnimation {
                        prefs.popoverHiddenFuturesIDs = []
                        showHiddenSection = false
                    }
                } label: {
                    Text(L("futures.hidden.restoreAll", comment: ""))
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
    }

    /// 单击行:展开/收起当日分时(手风琴,状态由 IntradayStore 全局单持)。
    private func toggleIntraday(_ target: IntradayTarget) {
        withAnimation(.easeInOut(duration: 0.2)) {
            intraday.toggle(target: target)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(L("futures.empty", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct FuturesRow: View {
    let quote: FuturesQuote
    let scheme: TickerColorScheme
    /// 价格显示小数位数(用户设置,与指数/个股一致)。
    let priceFractionDigits: Int
    /// 该行分时区是否展开(行尾 chevron 提示)。
    let isExpanded: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.descriptor.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(quote.descriptor.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatPrice(quote.price))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    let color: Color = quote.change >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
                    Text(signed(quote.change))
                        .font(.system(size: 10))
                        .foregroundColor(color)
                        .monospacedDigit()
                    Text(String(format: "%+.2f%%", quote.changePct * 100))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                        .monospacedDigit()
                }
            }
            expandChevron
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var expandChevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 10)
    }

    private func formatPrice(_ price: Decimal) -> String {
        let fmt = NumberFormatter()
        fmt.minimumFractionDigits = priceFractionDigits
        fmt.maximumFractionDigits = priceFractionDigits
        fmt.usesGroupingSeparator = true
        return fmt.string(from: NSDecimalNumber(decimal: price)) ?? "\(price)"
    }

    private func signed(_ value: Decimal) -> String {
        let sign = value >= 0 ? "+" : ""
        let fmt = NumberFormatter()
        fmt.minimumFractionDigits = priceFractionDigits
        fmt.maximumFractionDigits = priceFractionDigits
        return sign + (fmt.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)")
    }
}
