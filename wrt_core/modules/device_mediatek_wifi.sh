#!/usr/bin/env bash
# MEDIATEK-WIFI-YES / MEDIATEK-WIFI-YES_dae 专用: 修复 kmod 文件冲突
# 仅在 DEV_NAME == MEDIATEK-WIFI-YES / MEDIATEK-WIFI-YES_dae 时生效, 不影响其它设备。
#
# 背景: 上游(VIKINGYFY immortalwrt owrt 分支, ImmortalWrt 官方同结构)近期把
# ip_tables.ko / x_tables.ko 拆分进 hidden 包 kmod-iptables, 但 include/netfilter.mk
# 的 NF_IPT 模块列表未同步清理, 仍把这两个模块同时打包进 kmod-nf-ipt,
# 导致 kmod-nf-ipt 与 kmod-iptables 文件冲突 (opkg check_data_file_clashes),
# s20 固件 package/install 阶段 Cannot install kmod-nf-ipt / kmod-nf-ipt6 /
# kmod-ipt-core / kmod-nft-compat, 编译最终失败。
# rk356x (G68/G18, main 分支) 内核 config 未开启 legacy iptables 模块,
# kmod-nf-ipt 本就不含这两个模块, 不受影响, 因此该修复只对 MEDIATEK 系列应用。

# 入口: 由 update.sh stage_pre_install_source_fixes 调用。
fix_mediatek_netfilter_kmod_clash() {
    [[ "$DEV_NAME" == "MEDIATEK-WIFI-YES" || "$DEV_NAME" == "MEDIATEK-WIFI-YES_dae" ]] || return 0

    local nfm="$BUILD_DIR/include/netfilter.mk"
    [[ -f "$nfm" ]] || {
        echo "Error: [MEDIATEK-WIFI] 找不到 include/netfilter.mk: $nfm" >&2
        return 1
    }

    local bad1='$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables)'
    local bad2='$(call nf_add,NF_IPT,CONFIG_NETFILTER_XTABLES, $(P_XT)x_tables)'
    local ln

    # 幂等: 两行均已不存在则视为已修复, 跳过。
    if ! grep -qF -- "$bad1" "$nfm" && ! grep -qF -- "$bad2" "$nfm"; then
        echo "==> [MEDIATEK-WIFI] netfilter.mk NF_IPT 已修复, 跳过"
        return 0
    fi

    echo "==> [MEDIATEK-WIFI] 修复 kmod 文件冲突: NF_IPT 移除 ip_tables/x_tables 归属"
    ln=$(grep -nF -- "$bad1" "$nfm" | head -1 | cut -d: -f1)
    if [[ -n "$ln" ]]; then
        sed -i "${ln}d" "$nfm"
        echo "    - 已删除: $bad1"
    fi
    ln=$(grep -nF -- "$bad2" "$nfm" | head -1 | cut -d: -f1)
    if [[ -n "$ln" ]]; then
        sed -i "${ln}d" "$nfm"
        echo "    - 已删除: $bad2"
    fi

    # 校验: 两个模块归属行已移除, 不再打进 kmod-nf-ipt
    if grep -qF -- "$bad1" "$nfm" || grep -qF -- "$bad2" "$nfm"; then
        echo "Error: [MEDIATEK-WIFI] NF_IPT 归属清理失败, 仍有残留" >&2
        return 1
    fi
    echo "    - 校验通过: kmod-nf-ipt 不再打包 ip_tables.ko/x_tables.ko (由 hidden kmod-iptables 提供)"
    return 0
}
