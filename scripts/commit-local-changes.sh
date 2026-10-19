#!/bin/bash
# 提交本地功能改动 + 构建/环境文档(共 2 个 commit)
#
# 用法: bash scripts/commit-local-changes.sh
#
# 背景: TRAE 会话沙箱禁止写 .git 目录,git add/commit 需在用户终端执行。

set -e
cd "$(dirname "$0")/.."

# ---- 1) 面板汇总卡片显隐开关 ----
git add PanBar/Data/Persistence/Repositories/SettingsRepository.swift \
        PanBar/Infrastructure/TickerPreferences.swift \
        PanBar/Popover/Views/SummaryCards.swift \
        PanBar/Popover/Views/PopoverRoot.swift \
        PanBar/Settings/Panes/GeneralPane.swift \
        PanBar/Resources/Localizable.xcstrings
git commit -m "Add show/hide toggles for popover summary cards

Three new general-settings switches (Today / All-Time / Total Assets)
control the summary cards at the top of the popover. Each card hides
independently; hiding all three collapses the whole section. Settings
persist to SQLite (popover_show_* keys), default all visible."

# ---- 2) 构建脚本修复 + 排查文档 ----
git add Makefile docs/BUILD.md docs/TROUBLESHOOTING.md scripts/commit-local-changes.sh
git commit -m "Fix make build toolchain resolution and add troubleshooting guide

Makefile now exports DEVELOPER_DIR (xcode-select may point to
CommandLineTools) and resolves packages before building with an
explicit macOS destination. docs/TROUBLESHOOTING.md documents the
verified workarounds (offline GRDB mirror, macro sandbox flags)."

git log --oneline -3
git status --short
