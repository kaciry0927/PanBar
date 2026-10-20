import SwiftUI

struct IndicesTab: View {
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences
    @EnvironmentObject var vm: PopoverViewModel   // 拿 settingsRepo 读浏览器模板
    @EnvironmentObject var intraday: IntradayStore

    /// 已隐藏指数管理区是否展开。
    @State private var showHiddenSection = false

    /// 大盘 Tab 显示的指数 = 全量 - 用户隐藏的。
    private var visibleQuotes: [IndexQuote] {
        refresher.indexQuotes.filter { !prefs.popoverHiddenIndexIDs.contains($0.id) }
    }
    private var hiddenQuotes: [IndexQuote] {
        refresher.indexQuotes.filter { prefs.popoverHiddenIndexIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if refresher.indexQuotes.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleQuotes) { q in
                        // 整行用 Button(onTapGesture 会与 contextMenu 手势冲突)
                        Button {
                            toggleIntraday(.index(q.descriptor))
                        } label: {
                            IndexRow(quote: q, scheme: prefs.colorScheme, priceFractionDigits: prefs.priceFractionDigits, isExpanded: intraday.expandedKey == q.id)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("action.openInBrowser", comment: "")) {
                                openInBrowser(q.descriptor)
                            }
                            Divider()
                            Button(L("indices.hide", comment: "")) {
                                withAnimation {
                                    _ = prefs.popoverHiddenIndexIDs.insert(q.id)
                                }
                            }
                        }
                        if intraday.expandedKey == q.id {
                            IntradaySectionView(target: .index(q.descriptor), key: q.id, scheme: prefs.colorScheme)
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
    }

    /// 底部"已隐藏指数"折叠区:可逐个恢复,也可一键全部恢复。
    private var hiddenSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { showHiddenSection.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                    Text(String(format: L("indices.hiddenCount", comment: ""), hiddenQuotes.count))
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
                        if let market = q.descriptor.market {
                            Text(market.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .opacity(0.7)
                        }
                        Spacer()
                        Button {
                            withAnimation {
                                _ = prefs.popoverHiddenIndexIDs.remove(q.id)
                            }
                        } label: {
                            Label(L("indices.hidden.show", comment: ""), systemImage: "eye")
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
                        prefs.popoverHiddenIndexIDs = []
                        showHiddenSection = false
                    }
                } label: {
                    Text(L("indices.hidden.restoreAll", comment: ""))
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

    private func openInBrowser(_ index: IndexDescriptor) {
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if let url = BrowserURLBuilder.url(template: template, index: index) {
            NSWorkspace.shared.open(url)
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
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(L("indices.empty", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct IndexRow: View {
    let quote: IndexQuote
    let scheme: TickerColorScheme
    /// 指数点位显示小数位数(用户设置)。
    let priceFractionDigits: Int
    /// 该行分时区是否展开(行尾 chevron 提示)。
    let isExpanded: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.descriptor.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if let market = quote.descriptor.market {
                    Text(market.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
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
