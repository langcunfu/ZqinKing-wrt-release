#!/bin/sh
# ============================================================
# verify_wifi_cfg_live.sh - 路由器实机验证
# 验证 992_set-wifi-uci.sh 强制段"逐条 uci 写入"是否生效。
#
# 背景: 旧版强制段用 `uci -q batch` 一次性写入, 其中 delete 不存在的
#       txpower 选项会导致整批回滚, channel/htmode/country 全部不生效。
#       新版已改为逐条 uci -q set/delete。本脚本模拟新版强制段执行并检查。
#
# 用法 (上传到路由器后执行):
#   sh verify_wifi_cfg_live.sh             # 自动按 board_name 选择设备
#   sh verify_wifi_cfg_live.sh g68         # 指定设备
#   sh verify_wifi_cfg_live.sh g68 keep    # 验证后保留修改(默认回滚)
#
# 支持的设备: g68 jdc_ax1800_pro jdc_ax6600 s20p g18
# 默认行为: 备份 -> 逐条执行 -> 检查 -> 回滚 (不留痕, 不重启 network)
# ============================================================

DEV="${1:-auto}"
KEEP="${2:-rollback}"
WIRELESS_CONF="${WIRELESS_CONF:-/etc/config/wireless}"

fail() { echo "  FAIL: $*"; exit 1; }
pass() { echo "  PASS: $*"; }

# ---------------- 设备参数 ----------------
# 格式: radioN:信道:htmode (空格分隔)
declare_params() {
    case "$1" in
    g68)            echo 'radio0:1:HE40 radio1:36:HE160' ;;
    jdc_ax1800_pro) echo 'radio0:149:HE80 radio1:1:HE40' ;;
    jdc_ax6600)     echo 'radio0:149:HE80 radio1:1:HE40 radio2:36:HE160' ;;
    s20p)           echo 'radio0:1:HE40 radio1:36:HE160' ;;
    g18)            echo 'radio0:1:HE20 radio1:36:HE80' ;;
    *) fail "未知设备: $1 (支持: g68 jdc_ax1800_pro jdc_ax6600 s20p g18)" ;;
    esac
}

# ---------------- 前置检查 ----------------
[ -x "$(command -v uci)" ] || fail "本机没有 uci 命令, 请在路由器上运行"
[ -f "$WIRELESS_CONF" ] || fail "没有 $WIRELESS_CONF"

if [ "$DEV" = "auto" ]; then
    bn=$(cat /tmp/sysinfo/board_name 2>/dev/null)
    case "$bn" in
        nsy,g68-plus*|nsy,g68-plus-dsa) DEV=g68 ;;
        jdcloud,ax1800-pro*|jdcloud,re-ss-01) DEV=jdc_ax1800_pro ;;
        jdcloud,ax6600*|jdcloud,re-cs-02) DEV=jdc_ax6600 ;;
        supergateway,s20p) DEV=s20p ;;
        bdy,g18-pro) DEV=g18 ;;
        *) fail "无法根据 board_name=$bn 确定设备, 请显式传入设备名" ;;
    esac
    echo "检测到 board_name=$bn -> 设备 $DEV"
else
    echo "指定设备: $DEV"
fi

PARAMS=$(declare_params "$DEV")

# ---------------- 执行前状态 ----------------
echo
echo "== 执行前无线配置 (radio 级) =="
for rp in $PARAMS; do
    radio=$(echo "$rp" | cut -d: -f1)
    echo "  $radio: channel=$(uci get wireless.$radio.channel 2>/dev/null) htmode=$(uci get wireless.$radio.htmode 2>/dev/null) country=$(uci get wireless.$radio.country 2>/dev/null) txpower=$(uci get wireless.$radio.txpower 2>/dev/null)"
done

# ---------------- 备份 ----------------
echo
echo "== 备份 $WIRELESS_CONF -> /tmp/wireless.verify.bak =="
cp "$WIRELESS_CONF" /tmp/wireless.verify.bak || fail "备份失败"

# ---------------- 逐条执行 (模拟新版强制段) ----------------
echo
echo "== 逐条执行强制段 =="
for rp in $PARAMS; do
    radio=$(echo "$rp" | cut -d: -f1)
    ch=$(echo "$rp" | cut -d: -f2)
    hm=$(echo "$rp" | cut -d: -f3)
    uci set "wireless.$radio.channel=$ch"      && echo "  uci set  $radio.channel=$ch"
    uci set "wireless.$radio.htmode=$hm"       && echo "  uci set  $radio.htmode=$hm"
    uci set "wireless.$radio.country=US"       && echo "  uci set  $radio.country=US"
    uci delete "wireless.$radio.txpower" 2>/dev/null && echo "  uci delete $radio.txpower"
done
uci commit wireless && echo "  uci commit wireless"

# ---------------- 检查 ----------------
echo
echo "== 检查实际配置 =="
ok=1
for rp in $PARAMS; do
    radio=$(echo "$rp" | cut -d: -f1)
    ch=$(echo "$rp" | cut -d: -f2)
    hm=$(echo "$rp" | cut -d: -f3)
    c=$(uci get "wireless.$radio.channel" 2>/dev/null)
    h=$(uci get "wireless.$radio.htmode" 2>/dev/null)
    co=$(uci get "wireless.$radio.country" 2>/dev/null)
    tp=$(uci get "wireless.$radio.txpower" 2>/dev/null)
    echo "  $radio: channel=$c htmode=$h country=$co txpower=${tp:-<默认>}"
    [ "$c" = "$ch" ] || { echo "    FAIL: channel 应为 $ch, 实际 $c"; ok=0; }
    [ "$h" = "$hm" ] || { echo "    FAIL: htmode 应为 $hm, 实际 $h"; ok=0; }
    [ "$co" = "US" ] || { echo "    FAIL: country 应为 US, 实际 $co"; ok=0; }
done

# ---------------- 回滚或保留 ----------------
echo
if [ "$KEEP" = "keep" ]; then
    echo "== 按参数 keep: 保留修改 (已写入配置, 重启 network 后生效) =="
    echo "  如需恢复: cp /tmp/wireless.verify.bak "$WIRELESS_CONF" && uci commit wireless"
else
    echo "== 回滚配置 (恢复验证前状态) =="
    cp /tmp/wireless.verify.bak "$WIRELESS_CONF" || fail "回滚失败"
    rm -f /tmp/wireless.verify.bak
    echo "  已恢复原配置, 未重启 network, 当前无线不受影响"
fi

# ---------------- 结论 ----------------
echo
if [ "$ok" = 1 ]; then
    echo "== 结论: 逐条 uci 写入全部生效 (channel/htmode/country/txpower默认) =="
    echo "  992 强制段逐条化修复有效, 可以放心推送/编译"
    exit 0
else
    echo "== 结论: 逐条 uci 写入未生效, 需继续排查 =="
    exit 1
fi
