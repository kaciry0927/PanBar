import SwiftUI

struct WatchlistTab: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var appearance: AppearancePreferences
    @EnvironmentObject var prefs: TickerPreferences
    @EnvironmentObject var intraday: IntradayStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if vm.watchlist.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.watchlist) { item in
                            let key = item.symbol.storageKey
                            // 用 Button 而不是 onTapGesture:macOS 上 contextMenu 的手势
                            // 识别器会干扰 tap gesture(实测行体点击时常不响应,只有
                            // 行尾小箭头碰巧可点),Button 走独立点击路径,整行都是命中区。
                            Button {
                                toggleIntraday(.stock(item.symbol))
                            } label: {
                                WatchRow(item: item, quote: refresher.quotes[item.symbol], density: appearance.density, scheme: prefs.colorScheme, priceFractionDigits: prefs.priceFractionDigits, isExpanded: intraday.expandedKey == key)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(L("action.openInBrowser", comment: "")) {
                                    openInBrowser(item.symbol)
                                }
                                Divider()
                                Button(L("action.delete", comment: ""), role: .destructive) {
                                    vm.deleteWatchItem(item.id)
                                }
                            }
                            if intraday.expandedKey == key {
                                IntradaySectionView(target: .stock(item.symbol), key: key, scheme: prefs.colorScheme)
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .thinScrollbar()
            .frame(maxHeight: 290)

            if !vm.watchlist.isEmpty {
                Button(action: openAddSheet) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text(L("watchlist.quickAdd", comment: ""))
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
        }
    }

    private func openAddSheet() {
        SettingsWindowController.shared.show(initialAction: .addWatch)
    }

    /// 单击行:展开/收起当日分时(手风琴,状态由 IntradayStore 全局单持)。
    /// 不与双击手势并存——双击会让单击等 ~250ms 判定,展开手感卡顿;
    /// 浏览器入口保留在右键菜单。
    private func toggleIntraday(_ target: IntradayTarget) {
        withAnimation(.easeInOut(duration: 0.2)) {
            intraday.toggle(target: target)
        }
    }

    private func openInBrowser(_ symbol: SymbolID) {
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if let url = BrowserURLBuilder.url(template: template, symbol: symbol) {
            NSWorkspace.shared.open(url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(L("watchlist.empty", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(L("watchlist.quickAdd", comment: "")) {
                openAddSheet()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct WatchRow: View {
    let item: WatchItem
    let quote: Quote?
    let density: PopoverDensity
    let scheme: TickerColorScheme
    /// 价格显示小数位数(用户设置)。
    let priceFractionDigits: Int
    /// 该行分时区是否展开(行尾 chevron 提示)。
    let isExpanded: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol.market == .us ? item.symbol.code.uppercased() : item.symbol.code)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let q = quote {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.symbol.market.defaultCurrency.format(q.price, fractionDigits: priceFractionDigits))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Text(String(format: "%+.2f%%", q.changePct * 100))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(q.change >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme))
                        .monospacedDigit()
                }
            } else {
                Text("--")
                    .foregroundColor(.secondary)
            }
            expandChevron
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, max(density.rowVerticalPadding - 1, 4))
    }

    private var expandChevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 10)
    }
}
