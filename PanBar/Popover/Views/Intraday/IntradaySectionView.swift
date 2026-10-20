import SwiftUI

/// 展开区固定高度(图表 126 + 底部留白)。
/// 三态必须等高:loading → chart 切换时不再改变 popover 内容高度,
/// 避免触发 NSPopover 窗口尺寸动画期间的布局重入崩溃。
private let sectionHeight: CGFloat = 140

/// 行展开后的分时区(三个 Tab 复用):loading / error / 图表三态。
/// 数据与轮询全部来自 IntradayStore,自身不持有状态。
///
/// ⚠️ 展开区的挂载/卸载必须是调用方的"条件插入 + withAnimation"这一种方式
/// (第一轮实测稳定)。不要引入自管理 mounted 状态机/延迟卸载/双层裁剪:
/// NSPopover 的 preferredContentSize 随内容逐帧变化时,任何落在 AppKit 原子
/// 布局过程中的 SwiftUI 失效都会在 _postWindowNeedsUpdateConstraints 断言
/// 崩溃(SIGABRT,已炸过两次,见 2026-10-20 两份 .ips)。
struct IntradaySectionView: View {
    @EnvironmentObject var store: IntradayStore
    let target: IntradayTarget
    /// 与 store 的 key 一致(股票 storageKey / 指数 descriptor.id)。
    let key: String
    let scheme: TickerColorScheme

    var body: some View {
        Group {
            if let s = store.series[key] {
                IntradayChartView(series: s, scheme: scheme)
                    .frame(maxWidth: .infinity)
            } else if store.loadingKeys.contains(key) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("intraday.loading", comment: ""))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 错误态可点击立即重试(轮询本身 30s 也会自动重试)
                Button {
                    store.retry(target: target, key: key)
                } label: {
                    Text(store.errors[key] ?? L("intraday.failed", comment: ""))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(height: sectionHeight, alignment: .top)
    }
}
