#!/bin/sh
# ============================================================
# verify_wifi_cfg.sh - 验证 992_set-wifi-uci.sh 强制段逻辑
#
# 背景: 992 强制段原用 `uci -q batch` 一次写入, 其中 delete 不存在的
#       txpower 选项会导致整批回滚, channel/htmode/country 全部不生效。
#       现已改为逐条 uci -q set/delete。本脚本用于推送前验证。
#
# 用法:
#   开发机(无需 uci): bash verify_wifi_cfg.sh static
#   路由器(实机):    sh verify_wifi_cfg.sh live [g68|jdc_ax1800_pro|jdc_ax6600|s20p|g18]
#                    live 会 备份->逐条执行强制段->检查->回滚, 不留痕
# ============================================================

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
CFG="$SELF_DIR/992_set-wifi-uci.sh"
MODE="${1:-static}"
DEV="${2:-auto}"

fail() { echo "  FAIL: $*"; exit 1; }
pass() { echo "  PASS: $*"; }

# ---------------- 各设备期望值 ----------------
# 格式: 函数名|radio参数序列|SSID列表
# radio 参数: radioN:信道:htmode (空格分隔多个 radio)
declare_expected() {
    case "$1" in
    g68)
        echo 'nsy_g68_wifi_cfg|radio0:1:HE40 radio1:36:HE160|G68_2.4G,G68_5G'
        ;;
    jdc_ax1800_pro)
        echo 'jdc_ax1800_pro_wifi_cfg|radio0:149:HE80 radio1:1:HE40|JDC_AX1800PRO_5G,JDC_AX1800PRO'
        ;;
    jdc_ax6600)
        echo 'jdc_ax6600_wifi_cfg|radio0:149:HE80 radio1:1:HE40 radio2:36:HE160|JDC_AX6600_5G1,JDC_AX6600,JDC_AX6600_5G2'
        ;;
    s20p)
        echo 'nsy_s20p_wifi_cfg|radio0:1:HE40 radio1:36:HE160|S20_2.4G,S20_5G'
        ;;
    g18)
        echo 'nsy_g18_wifi_cfg|radio0:1:HE20 radio1:36:HE80|G18_2.4G,G18_5G'
        ;;
    *) fail "未知设备: $1" ;;
    esac
}

# ---------------- static: 开发机静态断言 ----------------
do_static() {
    [ -f "$CFG" ] || fail "找不到 $CFG"
    echo "== static 验证 =="
    echo "语法检查:"
    if bash -n "$CFG" 2>/dev/null; then pass "bash -n $CFG"; else fail "bash 语法错误"; fi

    for dev in g68 jdc_ax1800_pro jdc_ax6600 s20p g18; do
        spec=$(declare_expected "$dev")
        fn=$(echo "$spec" | cut -d'|' -f1)
        params=$(echo "$spec" | cut -d'|' -f2)
        echo "-- 设备 $dev ($fn) --"

        body=$(awk "/^$fn\(\) \{/,/^\}$/" "$CFG")
        [ -n "$body" ] || fail "$dev: 函数 $fn 未找到"

        # 强制段不能再用 batch(事务回滚根因)
        if ! echo "$body" | grep -q 'uci -q batch'; then pass "强制段已逐条化(无 batch)"; else fail "强制段仍含 batch"; fi

        n=0
        for rp in $params; do
            radio=$(echo "$rp" | cut -d: -f1)
            ch=$(echo "$rp" | cut -d: -f2)
            hm=$(echo "$rp" | cut -d: -f3)
            echo "$body" | grep -q "uci -q set wireless.$radio.channel='$ch'" || fail "$dev/$radio channel=$ch 未写入"
            echo "$body" | grep -q "uci -q set wireless.$radio.htmode='$hm'" || fail "$dev/$radio htmode=$hm 未写入"
            echo "$body" | grep -q "uci -q set wireless.$radio.country='US'" || fail "$dev/$radio country=US 未写入"
            echo "$body" | grep -q "uci -q delete wireless.$radio.txpower" || fail "$dev/$radio delete txpower 未写入"
            n=$((n+1))
        done
        pass "$dev: $n 个 radio 全部逐条写入 (channel/htmode/country/delete txpower)"

        echo "$body" | grep -q 'uci -q commit wireless' || fail "$dev: 缺少 uci commit wireless"
    done
    echo "== static 全部通过 =="
}

# ---------------- live: 路由器实机验证 ----------------
do_live() {
    [ -x "$(command -v uci)" ] || fail "本机没有 uci 命令, 请在路由器上运行"
    if [ "$DEV" = "auto" ]; then
        bn=$(cat /tmp/sysinfo/board_name 2>/dev/null)
        case "$bn" in
            nsy,g68-plus*|nsy,g68-plus-dsa) DEV=g68 ;;
            jdcloud,ax1800-pro*|jdcloud,re-ss-01) DEV=jdc_ax1800_pro ;;
            jdcloud,ax6600*|jdcloud,re-cs-02) DEV=jdc_ax6600 ;;
            supergateway,s20p) DEV=s20p ;;
            bdy,g18-pro) DEV=g18 ;;
            *) fail "无法根据 board_name=$bn 确定设备, 请显式传入" ;;
        esac
        echo "检测到 board_name=$bn -> 设备 $DEV"
    fi

    spec=$(declare_expected "$DEV")
    fn=$(echo "$spec" | cut -d'|' -f1)
    params=$(echo "$spec" | cut -d'|' -f2)

    echo "== live 验证: 设备 $DEV =="
    echo "备份 /etc/config/wireless -> /tmp/wireless.verify.bak"
    cp /etc/config/wireless /tmp/wireless.verify.bak || fail "备份失败"

    echo "执行强制段(radio 级):"
    for rp in $params; do
        radio=$(echo "$rp" | cut -d: -f1)
        ch=$(echo "$rp" | cut -d: -f2)
        hm=$(echo "$rp" | cut -d: -f3)
        uci set "wireless.$radio.channel=$ch"
        uci set "wireless.$radio.htmode=$hm"
        uci set "wireless.$radio.country=US"
        uci delete "wireless.$radio.txpower" 2>/dev/null
        echo "  set $radio: ch=$ch hm=$hm country=US, delete txpower"
    done
    uci commit wireless

    echo "检查实际配置:"
    ok=1
    for rp in $params; do
        radio=$(echo "$rp" | cut -d: -f1)
        ch=$(echo "$rp" | cut -d: -f2)
        hm=$(echo "$rp" | cut -d: -f3)
        c=$(uci get "wireless.$radio.channel" 2>/dev/null)
        h=$(uci get "wireless.$radio.htmode" 2>/dev/null)
        co=$(uci get "wireless.$radio.country" 2>/dev/null)
        echo "  $radio: channel=$c htmode=$h country=$co"
        [ "$c" = "$ch" ] || { echo "  FAIL: $radio channel 应为 $ch, 实际 $c"; ok=0; }
        [ "$h" = "$hm" ] || { echo "  FAIL: $radio htmode 应为 $hm, 实际 $h"; ok=0; }
        [ "$co" = "US" ] || { echo "  FAIL: $radio country 应为 US, 实际 $co"; ok=0; }
    done

    echo "回滚配置:"
    cp /tmp/wireless.verify.bak /etc/config/wireless || fail "回滚失败"
    rm -f /tmp/wireless.verify.bak
    echo "  已恢复原配置(未重启 network, 不影响当前无线)"

    if [ "$ok" = 1 ]; then
        echo "== live 验证通过: 逐条 uci 写入 channel/htmode/country 均生效 =="
    else
        echo "== live 验证失败: 逐条写入未生效 =="
        exit 1
    fi
}

# ---------------- stub: 开发机模拟 uci 运行验证 ----------------
do_stub() {
    [ -f "$CFG" ] || fail "找不到 $CFG"
    echo "== stub 运行验证 (模拟 uci 执行 G68 完整函数) =="
    STUB_LOG=$(mktemp)
    mkdir -p /tmp/sysinfo
    echo 'nsy,g68-plus' > /tmp/sysinfo/board_name

    uci() {
        case "$1" in
        batch) cat >/dev/null; echo "uci batch" >> "$STUB_LOG" ;;
        show)
            [ "$2" = "wireless" ] && printf 'wireless.default_radio0=wifi-iface\nwireless.default_radio1=wifi-iface\n'
            ;;
        get)
            case "$2" in
            wireless.default_radio0.device) echo radio0 ;;
            wireless.default_radio1.device) echo radio1 ;;
            wireless.radio0.band) echo 2g ;;
            wireless.radio1.band) echo 5g ;;
            esac
            ;;
        *) echo "uci $*" >> "$STUB_LOG" ;;
        esac
    }

    . "$CFG" 2>/dev/null  # 触发末尾 case -> board_name 匹配 g68 -> 执行完整函数

    echo "--- G68 捕获的 uci 调用(radio 级) ---"
    grep -E "uci -q (set|delete) wireless\.radio" "$STUB_LOG"

    echo "--- 断言 ---"
    ok=1
    for p in \
        "set wireless.radio0.channel=1" \
        "set wireless.radio0.htmode=HE40" \
        "set wireless.radio0.country=US" \
        "delete wireless.radio0.txpower" \
        "set wireless.radio1.channel=36" \
        "set wireless.radio1.htmode=HE160" \
        "set wireless.radio1.country=US" \
        "delete wireless.radio1.txpower" \
        "set wireless.default_radio0.ssid=G68_2.4G" \
        "set wireless.default_radio1.ssid=G68_5G" \
        "set wireless.default_radio0.encryption=psk2+ccmp" \
        "set wireless.default_radio0.key=12345678"; do
        if grep -qF "uci -q $p" "$STUB_LOG"; then
            echo "  PASS: uci -q $p"
        else
            echo "  FAIL: 未捕获 uci -q $p"
            ok=0
        fi
    done
    # 必须无 batch(事务回滚根因已消除)
    if grep -q "uci batch" "$STUB_LOG"; then echo "  FAIL: 仍有 batch 调用"; ok=0; else echo "  PASS: 无 batch 调用"; fi

    rm -f /tmp/sysinfo/board_name
    rm -f "$STUB_LOG"

    [ "$ok" = 1 ] || fail "stub 运行验证失败"
    echo "== stub 运行验证通过: 逐条 uci set/delete 全部被实际调用 =="
}

case "$MODE" in
    static) do_static ;;
    live)   do_live ;;
    stub)   do_stub ;;
    *) echo "用法: $0 [static|stub|live [设备]]"; exit 1 ;;
esac
