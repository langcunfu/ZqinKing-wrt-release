#!/usr/bin/env bash

set -e
set -o errexit
set -o errtrace

error_handler() {
    echo "Error occurred in script at line: ${BASH_LINENO[0]}, command: '${BASH_COMMAND}'"
}

trap 'error_handler' ERR

REPO_URL=$1
REPO_BRANCH=$2
BUILD_DIR=$3
COMMIT_HASH=$4
DEV_NAME=$5

# 转换为绝对路径，避免后续 cd 后路径失效。
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$(pwd)/$BUILD_DIR"
fi

FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="27.x"
THEME_SET="argon"
LAN_ADDR="192.168.17.1"

SCRIPT_DIR=$(cd $(dirname $0) && pwd)
BASE_PATH=${BASE_PATH:-$SCRIPT_DIR}

# 按静态职责加载模块，执行顺序仍由本脚本统一控制。
source "$SCRIPT_DIR/modules/network.sh"
source "$SCRIPT_DIR/modules/repo.sh"
source "$SCRIPT_DIR/modules/feeds.sh"
source "$SCRIPT_DIR/modules/custom_feed.sh"
source "$SCRIPT_DIR/modules/verify.sh"
source "$SCRIPT_DIR/modules/docker.sh"
source "$SCRIPT_DIR/modules/cups.sh"
source "$SCRIPT_DIR/modules/feed_source_fixes.sh"
source "$SCRIPT_DIR/modules/package_source_updates.sh"
source "$SCRIPT_DIR/modules/target_fixes.sh"
source "$SCRIPT_DIR/modules/device_nsy_g68.sh"
source "$SCRIPT_DIR/modules/device_nsy_g68_dsa.sh"
source "$SCRIPT_DIR/modules/device_nsy_g18_pro.sh"
source "$SCRIPT_DIR/modules/device_jdcloud_dae.sh"
source "$SCRIPT_DIR/modules/luci_fixes.sh"
source "$SCRIPT_DIR/modules/service_fixes.sh"


# 阶段顺序不可随意调整：feeds install 前后依赖的目录不同。
stage_repo_checkout() {
    # 从干净的上游源码树开始，保证后续修正基线一致。
    clone_repo
    clean_up
    reset_feeds_conf
}

stage_upstream_feeds_update() {
    # 先生成上游 feeds/* 工作树。
    update_feeds
}

stage_feed_source_cleanup() {
    # 清理会与 custom_feed 替换包冲突的上游 feed 包。
    remove_unwanted_packages
    remove_tweaked_packages
}

stage_custom_feed_prepare() {
    # custom_feed 以 src-link 加入 feeds，仍属于 install 前阶段。
    install_custom_feed
}

stage_pre_install_source_fixes() {
    # 这里仅修改源码树与 feeds/*，不能依赖 package/feeds/*。
    update_homeproxy
    fix_default_set
    fix_miniupnpd
    update_golang
    change_dnsmasq2full
    fix_mk_def_depends

    update_default_lan_addr
    remove_something_nss_kmod
    update_affinity_script
    update_ath11k_fw
    # fix_mkpkg_format_invalid
    change_cpuusage
    update_tcping
    add_ax6600_led
    set_custom_task
    apply_passwall_tweaks
    update_nss_pbuf_performance
    set_build_signature
    update_nss_diag
    update_menu_location
    fix_compile_coremark
    update_dnsmasq_conf
    add_backup_info_to_sysupgrade
    update_mosdns_deconfig
    fix_quickstart
    update_oaf_deconfig
    add_timecontrol
    add_quickfile
    update_lucky
    # fix_rust_compile_error  # 上游 48c1724 判定 obsolete, 已停用 (与上游一致)
    update_smartdns
    update_mwan3_fw4
    update_diskman
    update_dockerman
    set_nginx_default_config
    update_uwsgi_limit_as
    update_argon
    update_nginx_ubus_module
    check_default_settings
    install_opkg_distfeeds
    fix_easytier_mk
    remove_attendedsysupgrade
    fix_kconfig_recursive_dependency
    # VIKINGYFY 上游 900 patch 的 he_mu_edca 无条件访问修复 (加 ifdef 保护, 所有设备生效, 11ax 行为不变)
    fix_hostapd_muedca_900
    # luci-theme-argon (LUCI_BASENAME=argon-config) 与上游 luci-app-argon-config
    # 同名 i18n 冲突修复: 移除上游 app 包 + theme 侧 argon-config.po 并强制重扫 (所有设备生效)
    fix_argon_config_i18n_duplicate

    # NSY G68-PLUS 设备支持注入 (仅 NSY_G68_immwrt 生效)
    add_nsy_g68_device_support
    # NSY G68-PLUS DSA 变体注入 (仅 NSY_G68_dsa 生效)
    add_nsy_g68_dsa_device_support
    # BDY G18-PRO 设备注入 (仅 NSY_G18_pro_immwrt 生效)
    add_nsy_g18_pro_device_support
    # jdcloud_ipq60xx_immwrt_dae: KERNEL_SIZE 6144k->12288k 补丁 (仅该设备生效)
    add_jdcloud_dae_kernel_size_patch
    # MEDIATEK-WIFI-YES / MEDIATEK-WIFI-YES_dae 与其它设备统一走公共
    # fix_netfilter_kmod_clash (上游方案: 6.12/6.18 下 kmod-iptables 不装,
    # 模块由 kmod-nf-ipt 打包, 消除重复文件 clash, dae/iptables 功能无损)
    fix_netfilter_kmod_clash
    # 上游失效补丁清理: VIKINGYFY rockchip/800-hwrng 的修复已合入 6.18.52 主线,
    # 保留会导致所有 rockchip 目标内核补丁应用失败, 构建时禁用。
    disable_stale_hwrng_patch
}

stage_feeds_install() {
    # install 后才会生成 package/feeds/*。
    install_feeds
}

# VIKINGYFY rockchip/800-hwrng 补丁的修复 (dev_err_probe) 已合入 6.18.52 主线,
# 该补丁在 6.18.52 上应用必然失败且功能冗余; 构建时改名为 .disabled 跳过。
disable_stale_hwrng_patch() {
    local patch_file
    patch_file=$(ls "$BUILD_DIR"/target/linux/rockchip/patches-*/800-hwrng-*.patch 2>/dev/null | head -1)
    if [[ -n "$patch_file" && -f "$patch_file" && "$patch_file" != *.disabled ]]; then
        mv "$patch_file" "$patch_file.disabled"
        echo "  [上游修复] 已禁用失效补丁: $(basename "$patch_file") (修复已合入 6.18.52 主线)"
    fi
}

stage_post_install_package_fixes() {
    # 这里处理已安装到 package/feeds/* 的包和最终一致性检查。
    verify_custom_feed_installed_paths
    docker_stack_sync_nftables_compat "$BUILD_DIR" "0"
    fix_cups_libcups_avahi_depends
    fix_easytier_lua
    update_adguardhome
    update_script_priority
    update_geoip
    fix_openssl_ktls
    fix_opkg_check
    fix_netfilter_kmod_clash
    fix_quectel_cm
    install_pbr_cmcc
    fix_pbr_ip_forward
    # apply_hash_fixes
}

main() {
    stage_repo_checkout
    stage_upstream_feeds_update
    stage_feed_source_cleanup
    stage_custom_feed_prepare
    stage_pre_install_source_fixes
    stage_feeds_install
    stage_post_install_package_fixes
}

main "$@"
