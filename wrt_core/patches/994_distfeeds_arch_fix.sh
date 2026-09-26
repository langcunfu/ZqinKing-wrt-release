#!/bin/sh
# 修正 opkg 在线源架构错配:
# 设备架构为 aarch64_generic、而 distfeeds.conf 源路径为 aarch64_cortex-a53 时,
# 统一替换为 aarch64_generic (与设备架构匹配, 否则 opkg 在线装包报架构不兼容)。
# 设备架构本身为 cortex-a53 的设备(源与设备匹配) 不受影响, 直接跳过。
[ -f /etc/opkg/distfeeds.conf ] || exit 0

# 读取设备架构 (/etc/openwrt_release 的 DISTRIB_ARCH)
arch=$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
[ -n "$arch" ] || exit 0

# 仅处理 aarch64_generic 设备, 其他架构(含 cortex-a53)跳过
[ "$arch" = "aarch64_generic" ] || exit 0

# 源里确实含 cortex-a53 才修正
grep -q "aarch64_cortex-a53" /etc/opkg/distfeeds.conf || exit 0

sed -i 's/aarch64_cortex-a53/aarch64_generic/g' /etc/opkg/distfeeds.conf
exit 0
