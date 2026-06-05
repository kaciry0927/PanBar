import AppKit
import SwiftUI

struct HoldingsTab: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var appearance: AppearancePreferences
    @EnvironmentObject var prefs: TickerPreferences
    /// 当前 hover 的行 id;有值时该行尾露出铅笔编辑按钮。
    @State private var hoveredID: UUID?

    /// 把 snapshot.positions 按 holding.id 建索引,O(1) 查找。
    private var positionsByID: [UUID: HoldingPosition] {
        Dictionary(uniqueKeysWithValues: refresher.snapshot.positions.map { ($0.holding.id, $0) })
    }

    private var holdingPopoverMetric: HoldingPopoverMetric {
        HoldingPopoverMetric(rawValue: vm.settingsRepo.string(SettingsRepository.Keys.holdingPopoverMetric) ?? "") ?? .allTime
    }

    private var metricsLayout: HoldingMetricsLayout {
        let metricMode = holdingPopoverMetric
        var trailingWidth: CGFloat = 96

        for holding in vm.holdings {
            let quote = refresher.quotes[holding.symbol] ?? positionsByID[holding.id]?.quote
            let position = positionsByID[holding.id]
            trailingWidth = max(
                trailingWidth,
                estimatedQuoteWidth(holding: holding, quote: quote),
                metricLineWidth(
                    label: metricMode.displayName,
                    value: nativeMetric(holding: holding, quote: quote, mode: metricMode),
                    currency: holding.currency
                ),
                baseMetricWidth(value: baseMetric(position: position, mode: metricMode), currency: refresher.snapshot.baseCurrency)
            )
        }

        return HoldingMetricsLayout(
            trailingColumnWidth: max(96, ceil(trailingWidth) + 2)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if vm.holdings.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.holdings) { holding in
                            // 编辑按钮以 hover 时是否显示的形式传给 HoldingRow,在 name 后面 inline 出现,
                            // 不再用 ZStack 覆盖右侧(挡住涨跌幅 pill)。
                            HoldingRow(
                                holding: holding,
                                quote: refresher.quotes[holding.symbol],
                                position: positionsByID[holding.id],
                                density: appearance.density,
                                scheme: prefs.colorScheme,
                                baseCurrency: refresher.snapshot.baseCurrency,
                                metricsLayout: metricsLayout,
                                metricMode: holdingPopoverMetric,
                                showEditButton: hoveredID == holding.id,
                                onEdit: { openEdit(holding) }
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    hoveredID = hovering ? holding.id : (hoveredID == holding.id ? nil : hoveredID)
                                }
                            }
                            .contextMenu {
                                Button(L("action.edit", comment: "")) { openEdit(holding) }
                                Button(L("action.openInBrowser", comment: "")) {
                                    openInBrowser(holding.symbol)
                                }
                                Divider()
                                Button(L("action.delete", comment: ""), role: .destructive) {
                                    vm.deleteHolding(holding.id)
                                }
                            }
                            .onTapGesture(count: 2) {
                                openInBrowser(holding.symbol)
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .frame(maxHeight: 290)

            if !vm.holdings.isEmpty {
                quickAddButton
            }
        }
    }

    private func openEdit(_ holding: Holding) {
        SettingsWindowController.shared.show(initialAction: .editHolding(holding.id))
    }

    private var quickAddButton: some View {
        Button(action: openAddSheet) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text(L("holdings.quickAdd", comment: ""))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            VStack(spacing: 0) {
                Divider().opacity(0.4)
                Spacer()
            }
        )
    }

    private func openAddSheet() {
        SettingsWindowController.shared.show(initialAction: .addHolding)
    }

    private func openInBrowser(_ symbol: SymbolID) {
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if let url = BrowserURLBuilder.url(template: template, symbol: symbol) {
            NSWorkspace.shared.open(url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(L("holdings.empty", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(L("holdings.addFirst", comment: "")) {
                openAddSheet()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func nativePnL(holding: Holding, quote: Quote?) -> Decimal? {
        guard let quote else { return nil }
        return (quote.price - holding.costPrice) * holding.quantity
    }

    private func nativeTodayPnL(holding: Holding, quote: Quote?) -> Decimal? {
        guard let quote else { return nil }
        return (quote.price - quote.prevClose) * holding.quantity
    }

    private func nativeMetric(holding: Holding, quote: Quote?, mode: HoldingPopoverMetric) -> Decimal? {
        switch mode {
        case .allTime:
            return nativePnL(holding: holding, quote: quote)
        case .today:
            return nativeTodayPnL(holding: holding, quote: quote)
        }
    }

    private func baseMetric(position: HoldingPosition?, mode: HoldingPopoverMetric) -> Decimal? {
        switch mode {
        case .allTime:
            return position?.basePnL
        case .today:
            return position?.baseTodayPnL
        }
    }

    private func estimatedQuoteWidth(holding: Holding, quote: Quote?) -> CGFloat {
        guard let quote else {
            return textWidth("—", size: 12, weight: .semibold)
        }
        let price = holding.currency.format(quote.price)
        let pct = String(format: "%+.2f%%", quote.changePct * 100)
        return textWidth(price, size: 12, weight: .semibold)
            + 5
            + textWidth(pct, size: 10, weight: .semibold)
            + 10
    }

    private func metricLineWidth(label: String, value: Decimal?, currency: Currency) -> CGFloat {
        textWidth(label, size: 10, weight: .medium)
            + 3
            + metricValueWidth(value: value, currency: currency)
    }

    private func metricValueWidth(value: Decimal?, currency: Currency) -> CGFloat {
        textWidth(value.map { signedPnL($0, currency: currency) } ?? "—", size: 11, weight: .semibold)
    }

    private func baseMetricWidth(value: Decimal?, currency: Currency) -> CGFloat {
        textWidth(value.map { "≈ " + signedPnL($0, currency: currency) } ?? "—", size: 11, weight: .semibold)
    }

    private func signedPnL(_ value: Decimal, currency: Currency) -> String {
        let sign = value >= 0 ? "+" : "-"
        return sign + currency.format(value.magnitude)
    }

    private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

private struct HoldingMetricsLayout {
    let trailingColumnWidth: CGFloat

    var totalWidth: CGFloat {
        trailingColumnWidth
    }
}

private struct HoldingRow: View {
    let holding: Holding
    /// 行情:从 refresher.quotes 同步取(冷启动时已从磁盘 seed)。
    let quote: Quote?
    /// snapshot.positions 中匹配的那条:含本位币换算等字段。snapshot 异步合成,可能晚于 quote。
    let position: HoldingPosition?
    let density: PopoverDensity
    let scheme: TickerColorScheme
    let baseCurrency: Currency
    let metricsLayout: HoldingMetricsLayout
    let metricMode: HoldingPopoverMetric
    /// hover 时显示 inline 编辑铅笔(放在 name 后面,不挡涨跌)
    let showEditButton: Bool
    let onEdit: () -> Void

    /// 只要有 quote(无论 position 有没有),立即就能算出原币种的盈亏。
    /// 本位币换算需要 FX,只能依赖 position。
    private var nativePnL: Decimal? {
        guard let q = quote else { return nil }
        return (q.price - holding.costPrice) * holding.quantity
    }

    private var nativeTodayPnL: Decimal? {
        guard let q = quote else { return nil }
        return (q.price - q.prevClose) * holding.quantity
    }

    private var selectedMetricValue: Decimal? {
        switch metricMode {
        case .allTime:
            return nativePnL
        case .today:
            return nativeTodayPnL
        }
    }

    private var selectedBaseMetric: Decimal? {
        switch metricMode {
        case .allTime:
            return position?.basePnL
        case .today:
            return position?.baseTodayPnL
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                titleLine
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Text(detailText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.85))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            metricsGrid
                .layoutPriority(3)
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.rowVerticalPadding)
    }

    private var metricsGrid: some View {
        VStack(alignment: .trailing, spacing: 4) {
            quoteHeader
                .frame(width: metricsLayout.trailingColumnWidth, alignment: .trailing)

            metricLine(
                label: metricMode.displayName,
                value: selectedMetricValue,
                currency: holding.currency,
                alignment: .trailing,
                width: metricsLayout.trailingColumnWidth
            )

            // 本位币换算依赖 FX,只能从 snapshot 拿。
            if holding.currency != baseCurrency,
               selectedBaseMetric != nil {
                baseMetric(value: selectedBaseMetric, alignment: .trailing, width: metricsLayout.trailingColumnWidth)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: metricsLayout.totalWidth, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var titleLine: some View {
        HStack(spacing: 4) {
            Text(displayCode(holding.symbol))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(holding.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help(L("action.edit", comment: ""))
            .opacity(showEditButton ? 1 : 0)
            .disabled(!showEditButton)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .accessibilityHidden(!showEditButton)
        }
    }

    @ViewBuilder
    private var quoteHeader: some View {
        HStack(spacing: 5) {
            if let q = quote {
                Text(holding.currency.format(q.price))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                pctPill(q.changePct)
            } else {
                Text("—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
    }

    private func baseMetric(
        value: Decimal?,
        alignment: Alignment,
        width: CGFloat? = nil
    ) -> some View {
        HStack(spacing: 0) {
            if let value {
                Text("≈ " + signedPnL(value, currency: baseCurrency))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(pnlColor(value).opacity(0.7))
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(width: width ?? metricsLayout.trailingColumnWidth, alignment: alignment)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func metricLine(
        label: String,
        value: Decimal?,
        currency: Currency,
        alignment: Alignment,
        width: CGFloat? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
            if let value {
                Text(signedPnL(value, currency: currency))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(pnlColor(value))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(width: width ?? metricsLayout.trailingColumnWidth, alignment: alignment)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func displayCode(_ s: SymbolID) -> String {
        s.market == .us ? s.code.uppercased() : s.code
    }

    private var detailText: String {
        let qtyDisplay = "\(holding.quantity)"
        let costDisplay = holding.currency.format(holding.costPrice, fractionDigits: 3)
        return String(format: L("holding.detail", comment: ""), qtyDisplay, costDisplay)
    }

    private func signedPnL(_ value: Decimal, currency: Currency) -> String {
        let sign = value >= 0 ? "+" : "-"
        return sign + currency.format(value.magnitude)
    }

    private func pnlColor(_ value: Decimal) -> Color {
        SemanticColors.directional(value, scheme: scheme)
    }

    private func pctPill(_ pct: Double) -> some View {
        let text = String(format: "%+.2f%%", pct * 100)
        let color: Color = pct >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .monospacedDigit()
    }
}
