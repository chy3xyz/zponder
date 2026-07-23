#!/usr/bin/env bash
# zponder 快速编译与二进制安装脚本
set -e

echo "🚀 开始编译 zponder (ReleaseFast 优化模式)..."
zig build -Doptimize=ReleaseFast

echo "📦 安装二进制至 ~/.local/bin/zponder ..."
mkdir -p "$HOME/.local/bin"
cp ./zig-out/bin/zponder "$HOME/.local/bin/zponder"
chmod +x "$HOME/.local/bin/zponder"

echo "🎉 安装完成！验证安装结果："
if command -v zponder >/dev/null 2>&1; then
    zponder version
else
    "$HOME/.local/bin/zponder" version
    echo ""
    echo "提示: 请将 ~/.local/bin 添加到您的系统的 PATH 环境变量中:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi
