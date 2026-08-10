#!/bin/bash
# 构建并安装 ThreeSwipeCopy 到 /Applications，然后启动
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 开始构建"
bash build.sh

APP_DIR="$PWD/dist/ThreeSwipeCopy.app"
DEST="/Applications/ThreeSwipeCopy.app"

echo "==> 复制到 /Applications"
rm -rf "$DEST"
ditto "$APP_DIR" "$DEST"

echo "==> 启动应用"
open "$DEST"

cat <<'MSG'

✅ 安装完成！

⚠️ 关键一步：请先改触控板设置（否则三指手势会被系统抢走）
打开 系统设置 > 触控板 > 更多手势：
  · 调度中心（Mission Control）→ 改为「四指上滑」或「关闭」
  · App 切换（App Exposé）→ 改为「四指下滑」或「关闭」

然后请做两步：
1. 打开 系统设置 > 隐私与安全性 > 辅助功能
   找到「三指复制粘贴」并打开开关（首次运行会自动弹出提示）
2. 回到任意文本/文件窗口：
   · 选中文字后，三指上滑 = 复制
   · 在目标位置，三指下滑 = 粘贴

提示：
· 菜单栏会出现一个手势图标，可暂停/交换方向/设置开机自启动
· 若方向反了，点菜单栏图标 →「方向：…」即可交换
· 若想开机自启动，先把应用装好后在菜单里点「开机自启动：已关闭」
· 排错看日志：tail -f ~/Library/Logs/ThreeSwipeCopy.log
MSG
