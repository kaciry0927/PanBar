#!/bin/bash
# 提交两批本地功能改动 + 构建文档(共 3 个 commit)
#
# 用法: bash scripts/commit-local-changes.sh
#
# 说明: IndicesTab.swift 同时包含两个功能的改动,commit 1 前会临时把
# 市场标签还原为原实现,保证该 commit 可独立编译;commit 2 恢复终态。

set -e
cd "$(dirname "$0")/.."

F=PanBar/Popover/Views/IndicesTab.swift

# ---- 1) 价格小数位数设置(仅此功能,IndicesTab 暂时回到 market 原实现) ----
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
new = '''                if let market = quote.descriptor.market {
                    Text(market.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }'''
old = '''                Text(quote.descriptor.market.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)'''
assert new in s, "market if-let block not found (already reverted?)"
open(p, "w").write(s.replace(new, old))
PY

git add PanBar/Infrastructure/TickerPreferences.swift \
        PanBar/Data/Persistence/Repositories/SettingsRepository.swift \
        PanBar/Settings/Panes/GeneralPane.swift \
        PanBar/MenuBar/StatusItemController.swift \
        PanBar/MenuBar/TickerRenderer.swift \
        PanBar/Popover/Views/HoldingsTab.swift \
        PanBar/Popover/Views/WatchlistTab.swift \
        PanBar/Popover/Views/IndicesTab.swift \
        PanBar/Popover/PopoverController.swift \
        PanBar/Resources/Localizable.xcstrings
git commit -m "Add configurable price fraction digits setting (#24)

New general-settings picker (2/3/4 digits, default 2) that applies to
menu bar ticker and portfolio/watchlist/index panel quotes."

# ---- 2) 恢复 IndicesTab 终态,提交新增指数 ----
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''                Text(quote.descriptor.market.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)'''
new = '''                if let market = quote.descriptor.market {
                    Text(market.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }'''
assert old in s, "market text block not found"
open(p, "w").write(s.replace(old, new))
PY

git add PanBar/Domain/Models/IndexDescriptor.swift \
        PanBar/Infrastructure/BrowserURLBuilder.swift \
        PanBar/Popover/Views/IndicesTab.swift \
        PanBar/Settings/Panes/TickerPane.swift
git commit -m "Add STAR 50, KOSPI and Nikkei 225 to index catalog

IndexDescriptor.market/currency become optional so global indices
without a matching Market enum value can be listed. Browser links
added for xueqiu/yahoo/tradingview templates (xueqiu has no KOSPI
page). EM secids: 1.000688 / 100.KS11 / 100.N225."

# ---- 3) 构建文档与本脚本 ----
git add docs/BUILD.md scripts/commit-local-changes.sh
git commit -m "Add local build guide (offline GRDB mirror, macro sandbox notes)"

git log --oneline -4
git status --short
