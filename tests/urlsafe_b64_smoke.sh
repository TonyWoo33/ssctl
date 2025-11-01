#!/usr/bin/env bash
set -euo pipefail

# 一个既含 '/' 又含 '+' 的标准 base64：YWE/Pj4+
# 它的 URL-safe 版本：YWE_Pj4-
urlsafe="YWE_Pj4-"

# 先把 URL-safe 还原为标准 base64
std=$(printf '%s' "$urlsafe" | tr -- '-_' '+/')

# 按长度补齐 '='（使长度变成 4 的倍数）
case $(( ${#std} % 4 )) in
  2) std="${std}==";;
  3) std="${std}=" ;;
esac

# 解码并打印结果，应该是：aa?>>>
printf '%s' "$std" | base64 --decode || true
echo
echo "OK"
