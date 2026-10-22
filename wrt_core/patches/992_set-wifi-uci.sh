#!/bin/sh

board_name=$(cat /tmp/sysinfo/board_name)

configure_wifi() {
	local radio=$1
	local channel=$2
	local htmode=$3
	local txpower=$4
	local ssid=$5
	local key=$6
	local encryption=${7:-"psk2+ccmp"} # 新增 encryption 参数，如果为空则默认为 psk2+ccmp
	local now_encryption=$(uci get wireless.default_radio${radio}.encryption)
	if [ -n "$now_encryption" ] && [ "$now_encryption" != "none" ]; then
		return 0
	fi
	uci -q batch <<EOF
set wireless.radio${radio}.channel="${channel}"
set wireless.radio${radio}.htmode="${htmode}"
set wireless.radio${radio}.mu_beamformer='1'
set wireless.radio${radio}.country='US'
[ -n "$txpower" ] && uci -q set wireless.radio${radio}.txpower="${txpower}"
set wireless.radio${radio}.cell_density='0'
set wireless.radio${radio}.disabled='0'
set wireless.default_radio${radio}.ssid="${ssid}"
set wireless.default_radio${radio}.encryption="${encryption}"
set wireless.default_radio${radio}.key="${key}"
set wireless.default_radio${radio}.ieee80211k='1'
set wireless.default_radio${radio}.time_advertisement='2'
set wireless.default_radio${radio}.time_zone='CST-8'
set wireless.default_radio${radio}.bss_transition='1'
set wireless.default_radio${radio}.wnm_sleep_mode='1'
set wireless.default_radio${radio}.wnm_sleep_mode_no_keys='1'
EOF
}

configure_wifi7() {
	local radio=$1
	local channel=$2
	local htmode=$3
	local txpower=$4
	local ssid=$5
	local key=$6
	local encryption=${7:-"psk2"} # 新增 encryption 参数，如果为空则默认为 psk2
	local now_encryption=$(uci -q get wireless.default_radio${radio}.encryption)
	local bandmode=$(uci -q get wireless.radio${radio}.band)
	if [ "$bandmode" = "6g" ] && [ "$now_encryption" = "$encryption" ]; then
		return 0
	fi
	if [ "$bandmode" != "6g" ] && [ -n "$now_encryption" ] && [ "$now_encryption" != "none" ]; then
		return 0
	fi
	uci -q batch <<EOF
set wireless.radio${radio}.channel="${channel}"
set wireless.radio${radio}.htmode="${htmode}"
set wireless.radio${radio}.disabled='0'
set wireless.radio${radio}.country='US'
set wireless.radio${radio}.sku_idx='0'
set wireless.radio${radio}.he_twt_responder='1'
set wireless.radio${radio}.cell_density='0'
set wireless.radio${radio}.txpower="${txpower}"
set wireless.radio${radio}.noscan='0'
set wireless.default_radio${radio}.ssid="${ssid}"
set wireless.default_radio${radio}.encryption="${encryption}"
set wireless.default_radio${radio}.key="${key}"
set wireless.default_radio${radio}.vif_txpower="${txpower}"
set wireless.default_radio${radio}.ieee80211k='1'
set wireless.default_radio${radio}.time_zone='CST-8'
set wireless.default_radio${radio}.bss_transition='1'
set wireless.default_radio${radio}.wmm='1'
EOF
	if [ "$bandmode" = "2g" ]; then
		uci -q batch <<EOF
set wireless.radio${radio}.legacy_rates='1'
set wireless.radio${radio}.sr_enable='1'
set wireless.radio${radio}.etxbfen='1'
EOF
	elif [ "$bandmode" = "5g" ]; then
		uci -q batch <<EOF
set wireless.radio${radio}.background_radar='0'
EOF
	elif [ "$bandmode" = "6g" ]; then
		uci -q batch <<EOF
set wireless.radio${radio}.lpi_enable='0'
EOF
	fi
}

jdc_ax1800_pro_wifi_cfg() {
	# radio0=5G(ch149), radio1=2.4G(ch1)
	# 与 G68 同方式: 首启一次性 (立即遍历已生成 iface + 一次性 hotplug 兜底首刷)。
	# 名称/信道保持原设置, 功率改驱动默认 (configure_wifi txpower 传空)。
	mkdir -p /etc/hotplug.d/ieee80211
	cat > /etc/hotplug.d/ieee80211/99-jdc-ax1800pro-wifi <<'EOF'
#!/bin/sh
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)
case "$board_name" in
	jdcloud,ax1800-pro|jdcloud,re-ss-01)
		for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
			ssid=$(uci -q get wireless.$iface.ssid)
			[ "$ssid" = "OWRT" ] || continue
			radio=$(uci -q get wireless.$iface.device)
			case "$radio" in
				radio0) uci -q set wireless.$iface.ssid='JDC_AX1800PRO_5G' ;;
				radio1) uci -q set wireless.$iface.ssid='JDC_AX1800PRO' ;;
			esac
		done
		uci -q commit wireless
		;;
esac
# 一次性: 执行完自删, 后续无线事件不再处理
rm -f /etc/hotplug.d/ieee80211/99-jdc-ax1800pro-wifi
exit 0
EOF
	chmod +x /etc/hotplug.d/ieee80211/99-jdc-ax1800pro-wifi
	# 当前已生成的 iface 立即设置 (仅覆盖默认 OWRT; 用户已自定义的保留)
	for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
		ssid=$(uci -q get wireless.$iface.ssid)
		[ "$ssid" = "OWRT" ] || continue
		radio=$(uci -q get wireless.$iface.device)
		case "$radio" in
			radio0) uci -q set wireless.$iface.ssid='JDC_AX1800PRO_5G' ;;
			radio1) uci -q set wireless.$iface.ssid='JDC_AX1800PRO' ;;
		esac
	done
	configure_wifi 0 149 HE80 '' 'JDC_AX1800PRO_5G' '12345678'
	configure_wifi 1 1 HE40 '' 'JDC_AX1800PRO' '12345678'
}

jdc_ax6600_wifi_cfg() {
	# radio0=5G1(ch149), radio1=2.4G(ch1), radio2=5G2(ch36, 原44)
	# 与 G68 同方式: 首启一次性 (立即遍历已生成 iface + 一次性 hotplug 兜底首刷)。
	# 名称保持原设置, 功率改驱动默认 (configure_wifi txpower 传空), radio2 信道 44->36。
	mkdir -p /etc/hotplug.d/ieee80211
	cat > /etc/hotplug.d/ieee80211/99-jdc-ax6600-wifi <<'EOF'
#!/bin/sh
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)
case "$board_name" in
	jdcloud,ax6600|jdcloud,re-cs-02)
		for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
			ssid=$(uci -q get wireless.$iface.ssid)
			[ "$ssid" = "OWRT" ] || continue
			radio=$(uci -q get wireless.$iface.device)
			case "$radio" in
				radio0) uci -q set wireless.$iface.ssid='JDC_AX6600_5G1' ;;
				radio1) uci -q set wireless.$iface.ssid='JDC_AX6600' ;;
				radio2) uci -q set wireless.$iface.ssid='JDC_AX6600_5G2' ;;
			esac
		done
		uci -q commit wireless
		;;
esac
# 一次性: 执行完自删, 后续无线事件不再处理
rm -f /etc/hotplug.d/ieee80211/99-jdc-ax6600-wifi
exit 0
EOF
	chmod +x /etc/hotplug.d/ieee80211/99-jdc-ax6600-wifi
	# 当前已生成的 iface 立即设置 (仅覆盖默认 OWRT; 用户已自定义的保留)
	for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
		ssid=$(uci -q get wireless.$iface.ssid)
		[ "$ssid" = "OWRT" ] || continue
		radio=$(uci -q get wireless.$iface.device)
		case "$radio" in
			radio0) uci -q set wireless.$iface.ssid='JDC_AX6600_5G1' ;;
			radio1) uci -q set wireless.$iface.ssid='JDC_AX6600' ;;
			radio2) uci -q set wireless.$iface.ssid='JDC_AX6600_5G2' ;;
		esac
	done
	configure_wifi 0 149 HE80 '' 'JDC_AX6600_5G1' '12345678'
	configure_wifi 1 1 HE40 '' 'JDC_AX6600' '12345678'
	configure_wifi 2 36 HE160 '' 'JDC_AX6600_5G2' '12345678'
}

redmi_ax5_wifi_cfg() {
	configure_wifi 0 149 HE80 20 'Redmi_AX5_5G' '12345678'
	configure_wifi 1 1 HE20 20 'Redmi_AX5' '12345678'
}

aliyun_ap8220_wifi_cfg() {
	configure_wifi 0 149 HE80 26 'Aliyun_AP8220_5G' '12345678'
	configure_wifi 1 1 HE20 23 'Aliyun_AP8220' '12345678'
}

cmcc_rax3000m_wifi_cfg() {
	configure_wifi 0 1 HE20 23 'CMCC_RAX3000M' '12345678'
	configure_wifi 1 44 HE160 25 'CMCC_RAX3000M_5G' '12345678'
}

redmi_ax6_wifi_cfg() {
	configure_wifi 0 149 HE80 22 'Redmi_AX6_5G' '12345678'
	configure_wifi 1 1 HE20 21 'Redmi_AX6' '12345678'
}

qihoo_360v6_wifi_cfg() {
	configure_wifi 0 1 HE80 20 'Qihoo_360V6' '12345678'
	configure_wifi 1 149 HE20 20 'Qihoo_360V6_5G' '12345678'
}

linksys_mx4x00_wifi_cfg() {
	configure_wifi 0 1 HE20 22 'Linksys_MX4X00' '12345678'
	configure_wifi 1 149 HE80 21 'Linksys_MX4X00_5G1' '12345678'
	configure_wifi 2 44 HE80 21 'Linksys_MX4X00_5G2' '12345678'
}

gemtek_w1701k_wifi_cfg() {
	configure_wifi7 0 1 EHT20 23 'Gemtek_W1701K' '12345678'
	configure_wifi7 1 44 EHT160 23 'Gemtek_W1701K_5G' '12345678'
	configure_wifi7 2 1 EHT320 23 'Gemtek_W1701K_6G' '12345678' 'sae'
	uci set wireless.radio2.disabled='1'
}

link_nn6000_wifi_cfg() {
	configure_wifi 0 149 HE80 19 'Link_NN6000_5G' '12345678'
	configure_wifi 1 1 HT20 19 'Link_NN6000' '12345678'
}

nsy_g68_wifi_cfg() {
	# radio0=2.4G, radio1=5G (MT7916 双频)
	# 首启一次性: 立即遍历已生成的 iface (升级场景无线配置已存在)。
	# 另生成一次性 hotplug: 首刷时无线配置尚未生成, 首次无线接口创建后触发设置并自删, 之后不再处理。
	mkdir -p /etc/hotplug.d/ieee80211
	cat > /etc/hotplug.d/ieee80211/99-g68-ssid <<'EOF'
#!/bin/sh
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)
case "$board_name" in
	nsy,g68-plus|nsy,g68-plus-dsa)
		for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
			ssid=$(uci -q get wireless.$iface.ssid)
			[ "$ssid" = "OWRT" ] || continue
			radio=$(uci -q get wireless.$iface.device)
			band=$(uci -q get wireless.$radio.band)
			case "$band" in
				2g) uci -q set wireless.$iface.ssid='G68_2.4G' ;;
				5g) uci -q set wireless.$iface.ssid='G68_5G' ;;
			esac
		done
		uci -q commit wireless
		;;
esac
# 一次性: 执行完自删, 后续无线事件不再处理
rm -f /etc/hotplug.d/ieee80211/99-g68-ssid
exit 0
EOF
	chmod +x /etc/hotplug.d/ieee80211/99-g68-ssid
	# 当前已生成的 iface 立即设置 (仅覆盖默认 OWRT; 用户已自定义的保留)
	for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
		ssid=$(uci -q get wireless.$iface.ssid)
		[ "$ssid" = "OWRT" ] || continue
		radio=$(uci -q get wireless.$iface.device)
		band=$(uci -q get wireless.$radio.band)
		case "$band" in
			2g) uci -q set wireless.$iface.ssid='G68_2.4G' ;;
			5g) uci -q set wireless.$iface.ssid='G68_5G' ;;
		esac
	done
	configure_wifi 0 1 HE20 20 'G68_2.4G' '12345678'
	configure_wifi 1 36 HE80 20 'G68_5G' '12345678'
}

# G18 Pro (BDY): radio0=2.4G, radio1=5G (MT7615 双频)
# 与 G68 同方式: 首启一次性 (立即遍历已生成 iface + 一次性 hotplug 兜底首刷) + configure_wifi。
# 额外: 每台机器唯一 WiFi MAC (eMMC CID 派生), 避免多台同固件 BSSID/MAC 冲突。
nsy_g18_wifi_cfg() {
	. /lib/functions/system.sh
	local mac
	mac=$(macaddr_generate_from_mmc_cid mmcblk0 2>/dev/null)

	mkdir -p /etc/hotplug.d/ieee80211
	cat > /etc/hotplug.d/ieee80211/99-g18-wifi <<'EOF'
#!/bin/sh
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)
case "$board_name" in
	bdy,g18-pro)
		. /lib/functions/system.sh
		g18_mac=$(macaddr_generate_from_mmc_cid mmcblk0 2>/dev/null)
		# SSID (仅覆盖默认 OWRT; 用户已自定义的保留)
		for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
			ssid=$(uci -q get wireless.$iface.ssid)
			[ "$ssid" = "OWRT" ] || continue
			radio=$(uci -q get wireless.$iface.device)
			band=$(uci -q get wireless.$radio.band)
			case "$band" in
				2g) uci -q set wireless.$iface.ssid='G18_2.4G' ;;
				5g) uci -q set wireless.$iface.ssid='G18_5G' ;;
			esac
		done
		# 唯一 MAC (BSSID)
		if [ -n "$g18_mac" ] && [ -z "$(uci -q get wireless.default_radio0.macaddr)" ]; then
			uci -q set wireless.default_radio0.macaddr="$g18_mac"
			uci -q get wireless.default_radio1 >/dev/null && \
				uci -q set wireless.default_radio1.macaddr="$(macaddr_add "$g18_mac" 1)"
		fi
		uci -q commit wireless
		;;
esac
# 一次性: 执行完自删, 后续无线事件不再处理
rm -f /etc/hotplug.d/ieee80211/99-g18-wifi
exit 0
EOF
	chmod +x /etc/hotplug.d/ieee80211/99-g18-wifi
	# 当前已生成的 iface 立即设置 (仅覆盖默认 OWRT; 用户已自定义的保留)
	for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
		ssid=$(uci -q get wireless.$iface.ssid)
		[ "$ssid" = "OWRT" ] || continue
		radio=$(uci -q get wireless.$iface.device)
		band=$(uci -q get wireless.$radio.band)
		case "$band" in
			2g) uci -q set wireless.$iface.ssid='G18_2.4G' ;;
			5g) uci -q set wireless.$iface.ssid='G18_5G' ;;
		esac
	done
	# 唯一 MAC: 无线配置已存在时立即设置
	if [ -n "$mac" ] && [ -z "$(uci -q get wireless.default_radio0.macaddr)" ]; then
		uci -q set wireless.default_radio0.macaddr="$mac"
		uci -q get wireless.default_radio1 >/dev/null && \
			uci -q set wireless.default_radio1.macaddr="$(macaddr_add "$mac" 1)"
	fi
	configure_wifi 0 1 HE20 20 'G18_2.4G' '12345678'
	configure_wifi 1 36 HE80 20 'G18_5G' '12345678'
}

# S20P (Super Gateway S20P, MT7986A 双频):
#   - MEDIATEK-WIFI-YES / MEDIATEK-WIFI-YES_dae -> supergateway_s20p (VIKINGYFY owrt, 开源 mt7915e)
# 与 G68 同方式: 首启一次性 (立即遍历已生成 iface + 一次性 hotplug 兜底首刷)。
# 功率用驱动默认 (configure_wifi txpower 传空 => 跳过设置)。
nsy_s20p_wifi_cfg() {
	# radio0=2.4G, radio1=5G
	mkdir -p /etc/hotplug.d/ieee80211
	cat > /etc/hotplug.d/ieee80211/99-s20p-wifi <<'EOF'
#!/bin/sh
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)
case "$board_name" in
	supergateway,s20p)
		for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
			ssid=$(uci -q get wireless.$iface.ssid)
			[ "$ssid" = "OWRT" ] || continue
			radio=$(uci -q get wireless.$iface.device)
			band=$(uci -q get wireless.$radio.band)
			case "$band" in
				2g) uci -q set wireless.$iface.ssid='S20_2.4G' ;;
				5g) uci -q set wireless.$iface.ssid='S20_5G' ;;
			esac
		done
		uci -q commit wireless
		;;
esac
# 一次性: 执行完自删, 后续无线事件不再处理
rm -f /etc/hotplug.d/ieee80211/99-s20p-wifi
exit 0
EOF
	chmod +x /etc/hotplug.d/ieee80211/99-s20p-wifi
	# 当前已生成的 iface 立即设置 (仅覆盖默认 OWRT; 用户已自定义的保留)
	for iface in $(uci -q show wireless | grep "=wifi-iface" | sed 's/wireless\.\(.*\)=wifi-iface/\1/'); do
		ssid=$(uci -q get wireless.$iface.ssid)
		[ "$ssid" = "OWRT" ] || continue
		radio=$(uci -q get wireless.$iface.device)
		band=$(uci -q get wireless.$radio.band)
		case "$band" in
			2g) uci -q set wireless.$iface.ssid='S20_2.4G' ;;
			5g) uci -q set wireless.$iface.ssid='S20_5G' ;;
		esac
	done
	configure_wifi 0 1 HE40 '' 'S20_2.4G' '12345678'
	configure_wifi 1 36 HE80 '' 'S20_5G' '12345678'
}

case "${board_name}" in
supergateway,s20p)
	nsy_s20p_wifi_cfg
	;;
jdcloud,ax1800-pro | \
	jdcloud,re-ss-01)
	jdc_ax1800_pro_wifi_cfg
	;;
jdcloud,ax6600 | \
	jdcloud,re-cs-02)
	jdc_ax6600_wifi_cfg
	;;
redmi,ax5 | \
	redmi,ax5-jdcloud)
	redmi_ax5_wifi_cfg
	;;
aliyun,ap8220)
	aliyun_ap8220_wifi_cfg
	;;
cmcc,rax3000m)
	cmcc_rax3000m_wifi_cfg
	;;
redmi,ax6 | \
	redmi,ax6-stock)
	redmi_ax6_wifi_cfg
	;;
qihoo,360v6)
	qihoo_360v6_wifi_cfg
	;;
linksys,mx4200v1 | \
	linksys,mx4200v2 | \
	linksys,mx4300)
	linksys_mx4x00_wifi_cfg
	;;
gemtek,w1701k-ubi)
	gemtek_w1701k_wifi_cfg
	;;
link,nn6000-v2)
	link_nn6000_wifi_cfg
	;;
nsy,g68-plus | \
	nsy,g68-plus-dsa)
	nsy_g68_wifi_cfg
	;;
bdy,g18-pro)
	nsy_g18_wifi_cfg
	;;
*)
	exit 0
	;;
esac

uci commit wireless
/etc/init.d/network restart
