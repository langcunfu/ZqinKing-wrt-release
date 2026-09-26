#!/usr/bin/env bash
# LuCI 展示、菜单和前端相关修正。

set_build_signature() {
    local file="$BUILD_DIR/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
    if [ -d "$(dirname "$file")" ] && [ -f $file ]; then
        sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ build by langcunfu')/g" "$file"
    fi
}

# 防火墙页"Routing/NAT Offloading"(软件/硬件流卸载)区块改为无条件显示。
# 根因: zones.js 渲染时同步调用 L.hasSystemFeature('offloading'), 而 LuCI 特性探测是异步
# (RPC -> ubus getFeatures), 页面渲染先于探测完成时拿到 null -> 区块被跳过且不重渲染。
# 固件已编入 nft_flow_offload / xt_FLOWOFFLOAD (getFeatures 实测 offloading=true), 无需条件。
fix_firewall_offloading_display() {
    local zones_js="$BUILD_DIR/feeds/luci/applications/luci-app-firewall/htdocs/luci-static/resources/view/firewall/zones.js"
    if [ -f "$zones_js" ]; then
        sed -i "s/if *(L\.hasSystemFeature('offloading') *) *{/{/g" "$zones_js"
        echo "已修复: 防火墙流卸载区块改为无条件显示"
    else
        echo "警告: 未找到 zones.js ($zones_js), 跳过流卸载显示修复" >&2
    fi
}

update_menu_location() {
    local samba4_path="$BUILD_DIR/feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json"
    if [ -d "$(dirname "$samba4_path")" ] && [ -f "$samba4_path" ]; then
        sed -i 's/nas/services/g' "$samba4_path"
    fi

    local tailscale_path="$(get_custom_feed_worktree_dir)/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json"
    if [ -d "$(dirname "$tailscale_path")" ] && [ -f "$tailscale_path" ]; then
        sed -i 's/services/vpn/g' "$tailscale_path"
    fi
}


update_nginx_ubus_module() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    local source_date="2024-03-02"
    local source_version="564fa3e9c2b04ea298ea659b793480415da26415"
    local mirror_hash="92c9ab94d88a2fe8d7d1e8a15d15cfc4d529fdc357ed96d22b65d5da3dd24d7f"

    if [ -f "$makefile_path" ]; then
        sed -i "s/SOURCE_DATE:=2020-09-06/SOURCE_DATE:=$source_date/g" "$makefile_path"
        sed -i "s/SOURCE_VERSION:=b2d7260dcb428b2fb65540edb28d7538602b4a26/SOURCE_VERSION:=$source_version/g" "$makefile_path"
        sed -i "s/MIRROR_HASH:=515bb9d355ad80916f594046a45c190a68fb6554d6795a54ca15cab8bdd12fda/MIRROR_HASH:=$mirror_hash/g" "$makefile_path"
        echo "已更新 nginx-mod-ubus 模块的 SOURCE_DATE, SOURCE_VERSION 和 MIRROR_HASH。"
    else
        echo "错误：未找到 $makefile_path 文件，无法更新 nginx-mod-ubus 模块。" >&2
    fi
}
