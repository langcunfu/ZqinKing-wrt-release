#!/usr/bin/env bash
# NSY G68-PLUS 设备支持注入模块
#
# 背景: VIKINGYFY/immortalwrt 官方源码未收录 nsy-g68-plus 设备
# (无内核 DTS / armv8.mk 镜像定义 / U-Boot / RTL8367S 完整驱动)。
# 本模块仅在构建 NSY_G68_immwrt 时, 向源码树注入该设备所需的全部支持:
#   1. 内核 DTS 补丁 (patches-<ver>/, 同时服务 U-Boot OF_UPSTREAM)
#   2. rockchip image 设备定义 (target/linux/rockchip/image/armv8.mk)
#   3. U-Boot: defconfig + u-boot.dtsi + Makefile 设备定义
#   4. RTL8367S 交换驱动: rtl8367b.c / rtl8366_smi.c / 内核头文件 (SGMII 支持)
#   5. 板级网络配置: board.d/02_network + 40-net-smp-affinity
#
# 资产目录: wrt_core/patches/nsy_g68/

NSY_G68_ASSETS="$SCRIPT_DIR/patches/nsy_g68"

# 入口: 由 update.sh stage_pre_install_source_fixes 调用。
add_nsy_g68_device_support() {
    [[ "$DEV_NAME" == "NSY_G68_immwrt" ]] || return 0

    echo "==> [NSY_G68] 注入 nsy-g68-plus 设备支持 (VIKINGYFY/immortalwrt)"

    [[ -d "$BUILD_DIR/target/linux/rockchip" ]] || {
        echo "Error: [NSY_G68] 找不到 rockchip target 目录: $BUILD_DIR/target/linux/rockchip" >&2
        return 1
    }
    [[ -f "$NSY_G68_ASSETS/kernel/900-nsy-g68-arm64-boot-add-dts.patch" ]] || {
        echo "Error: [NSY_G68] 缺少内核 DTS 补丁资产" >&2
        return 1
    }

    inject_nsy_g68_kernel_dts
    inject_nsy_g68_image_def
    inject_nsy_g68_uboot
    inject_nsy_g68_switch_driver
    inject_nsy_g68_board_files
    inject_nsy_g68_wifi_firmware
    inject_nsy_g68_partition_layout

    echo "==> [NSY_G68] 设备支持注入完成"
}

# 分区布局: 32MiB 内核 + 2048MiB(rootfs, squashfs) 两分区, 不建独立 userdata 分区。
# overlay 由 mount_root 的 rootdisk 机制自动取 squashfs 尾部剩余空间 (p2 内)。
# gen_image_generic.sh 的 PADDING 填充对大 rootfs(>=1G) 跳过, 保证固件不因填充膨胀
# (2G rom 只写 ~155M squashfs 数据, 镜像保持 ~190M 可传入 /tmp)。
inject_nsy_g68_partition_layout() {
    local script="$BUILD_DIR/scripts/gen_image_generic.sh"
    [[ -f "$script" ]] || {
        echo "Error: [NSY_G68] 找不到 $script" >&2
        return 1
    }

    python3 - "$script" <<'PYEOF'
import sys
path = sys.argv[1]
s = open(path).read()
# PADDING 填充加阈值: rootfs 分区 >= 1G (2097152 扇区) 时跳过零填充,
# 避免 2048MiB rom 被 dd 成 2G+ 镜像; < 1G 的常规设备保持原行为不变。
old = '[ -n "$PADDING" ] && dd if=/dev/zero of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc count="$ROOTFSSIZE"'
new = '[ -n "$PADDING" ] && [ "$ROOTFSSIZE" -lt 2097152 ] && dd if=/dev/zero of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc count="$ROOTFSSIZE"'
if old not in s:
    print('Error: gen_image_generic.sh PADDING 行未匹配, 脚本结构可能已变化', file=sys.stderr)
    sys.exit(1)
s = s.replace(old, new, 1)
open(path, 'w').write(s)
print('  [板级] gen_image_generic.sh: rootfs >=1G 跳过 PADDING 填充 (镜像不膨胀)')
PYEOF
}

# 1. 内核 DTS: 将自包含补丁放入 target/linux/rockchip/patches-<ver>/
inject_nsy_g68_kernel_dts() {
    local patch_dir
    local patch_name="900-nsy-g68-arm64-boot-add-dts.patch"

    patch_dir=$(ls -d "$BUILD_DIR"/target/linux/rockchip/patches-* 2>/dev/null | sort -V | tail -1)
    [[ -n "$patch_dir" && -d "$patch_dir" ]] || {
        echo "Error: [NSY_G68] 找不到内核 patches 目录" >&2
        return 1
    }

    if [[ ! -f "$patch_dir/$patch_name" ]]; then
        install -m644 "$NSY_G68_ASSETS/kernel/$patch_name" "$patch_dir/$patch_name"
        echo "  [内核] 已安装 DTS 补丁 -> $patch_dir/$patch_name"
    fi

    # 调试补丁(临时): stmmac/phylink probe 逐步打印, 用于定位 fe2a0000 卡点
    # 定位完成后删除本段 (以及 assets/kernel/910-*.patch)
    if [[ -f "$NSY_G68_ASSETS/kernel/910-nsy-g68-debug-stmmac-phylink.patch" ]]; then
        install -m644 "$NSY_G68_ASSETS/kernel/910-nsy-g68-debug-stmmac-phylink.patch" \
            "$patch_dir/910-nsy-g68-debug-stmmac-phylink.patch"
        echo "  [内核] 已安装 stmmac/phylink 调试补丁 (DBG[probe]/DBG[phylink] 打印)"
    fi
}

# 2. 镜像定义: 向 armv8.mk 追加 Device/nsy_g68-plus
inject_nsy_g68_image_def() {
    local armv8_mk="$BUILD_DIR/target/linux/rockchip/image/armv8.mk"
    local marker="define Device/nsy_g68-plus"

    [[ -f "$armv8_mk" ]] || {
        echo "Error: [NSY_G68] 找不到 armv8.mk: $armv8_mk" >&2
        return 1
    }

    if ! grep -qE "^define Device/nsy_g68-plus$" "$armv8_mk"; then
        cat >> "$armv8_mk" <<'EOF'

# ============ NSY G68-PLUS (由 device_nsy_g68.sh 注入) ============
define Device/nsy_g68-plus
  $(Device/rk3568)
  DEVICE_VENDOR := NSY
  DEVICE_MODEL := G68-PLUS
  DEVICE_DTS := rk3568-nsy-g68-plus
  UBOOT_DEVICE_NAME := nsy-g68-plus-rk3568
  DEVICE_PACKAGES := kmod-mt7916-firmware kmod-switch-rtl8367b wpad-openssl
endef
TARGET_DEVICES += nsy_g68-plus
EOF
        echo "  [镜像] 已追加 Device/nsy_g68-plus -> $armv8_mk"
    fi
}

# 3. U-Boot: defconfig + u-boot.dtsi + Makefile 定义
inject_nsy_g68_uboot() {
    local uboot_dir="$BUILD_DIR/package/boot/uboot-rockchip"
    local uboot_mk="$uboot_dir/Makefile"

    [[ -d "$uboot_dir" ]] || {
        echo "Error: [NSY_G68] 找不到 uboot-rockchip 包: $uboot_dir" >&2
        return 1
    }

    # 3a. defconfig
    if [[ ! -f "$uboot_dir/src/configs/nsy-g68-plus-rk3568_defconfig" ]]; then
        install -Dm644 "$NSY_G68_ASSETS/uboot/nsy-g68-plus-rk3568_defconfig" \
            "$uboot_dir/src/configs/nsy-g68-plus-rk3568_defconfig"
        echo "  [U-Boot] 已安装 defconfig"
    fi

    # 3b. u-boot.dtsi (U-Boot 从 arch/arm/dts/ 顶层查找 *-u-boot.dtsi)
    if [[ ! -f "$uboot_dir/src/arch/arm/dts/rk3568-nsy-g68-plus-u-boot.dtsi" ]]; then
        install -Dm644 "$NSY_G68_ASSETS/uboot/rk3568-nsy-g68-plus-u-boot.dtsi" \
            "$uboot_dir/src/arch/arm/dts/rk3568-nsy-g68-plus-u-boot.dtsi"
        echo "  [U-Boot] 已安装 u-boot.dtsi (arch/arm/dts/)"
    fi

    # 3c. Makefile 设备定义
    if ! grep -q "nsy-g68-plus-rk3568" "$uboot_mk"; then
        awk '
            /^\$\(eval \$\(call BuildPackage\/U-Boot\)\)/ && !done {
                print "define U-Boot/nsy-g68-plus-rk3568"
                print "  $(U-Boot/rk3568/Default)"
                print "  NAME:=NSY G68 PLUS"
                print "  BUILD_DEVICES:= \\"
                print "    nsy_g68-plus"
                print "endef"
                print ""
                done = 1
            }
            { print }
        ' "$uboot_mk" > "$uboot_mk.tmp" && mv "$uboot_mk.tmp" "$uboot_mk"
        echo "  [U-Boot] 已注册 U-Boot/nsy-g68-plus-rk3568"
    fi

    # 3d. 加入 UBOOT_TARGETS 构建列表 (OpenWrt 只构建列表内的 U-Boot 设备)
    if ! grep -q "^  nsy-g68-plus-rk3568" "$uboot_mk"; then
        python3 - "$uboot_mk" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().split('\n')
in_list = False
last_item = None
for i, line in enumerate(lines):
    if line.startswith('UBOOT_TARGETS'):
        in_list = True
        continue
    if in_list:
        st = line.strip()
        if st == '' or not line.startswith(' '):
            in_list = False
        elif not line.rstrip().endswith('\\'):
            last_item = i
            in_list = False
if last_item is None:
    print('Error: 未找到 UBOOT_TARGETS 列表', file=sys.stderr)
    sys.exit(1)
lines[last_item] = lines[last_item].rstrip() + ' \\'
lines.insert(last_item + 1, '  nsy-g68-plus-rk3568')
open(path, 'w').write('\n'.join(lines))
print('  [U-Boot] 已加入 UBOOT_TARGETS: nsy-g68-plus-rk3568')
PYEOF
    fi

    # 3e. OF_UPSTREAM DTS: U-Boot 2026.07 默认从 dts/upstream 编译设备树。
    # 内核 DTS 基于 6.18 (含 &xpcs 节点), 但 U-Boot 快照 (rk3568.dtsi) 无 xpcs,
    # 生成 U-Boot 专用 DTS: 去掉 &xpcs 引用 (U-Boot 不需要 PCS 配置)。
    local upstream_dts_dir="$uboot_dir/src/dts/upstream/src/arm64/rockchip"
    mkdir -p "$upstream_dts_dir"
    if [[ ! -f "$upstream_dts_dir/rk3568-nsy-g68-plus.dts" ]]; then
        python3 - "$NSY_G68_ASSETS/kernel/rk3568-nsy-g68-plus.dts" \
            "$upstream_dts_dir/rk3568-nsy-g68-plus.dts" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# 删除 &xpcs { ... }; 整块
s2 = re.sub(r'&xpcs\s*\{[^}]*\};', '', s)
# 删除 gmac 里 rockchip,xpcs = <&xpcs>; 属性行
s2 = s2.replace('rockchip,xpcs = <&xpcs>;', '')
# 兜底: 清除残留的 &xpcs 引用
s2 = re.sub(r'&xpcs\b', '', s2)
if s2 == s:
    print('Warning: DTS 未找到 xpcs 引用, 可能结构已变', file=sys.stderr)
open(dst, 'w').write(s2)
print('  [U-Boot] 已生成 U-Boot 版 DTS (去掉 &xpcs)')
PYEOF
    fi
}

# 4. RTL8367S 交换驱动 (OpenWrt swconfig rtl8367b 驱动族)
inject_nsy_g68_switch_driver() {
    local files_dir="$BUILD_DIR/target/linux/generic/files"
    local phy_dir="$files_dir/drivers/net/phy"
    local inc_dir="$files_dir/include/linux"

    [[ -d "$phy_dir" && -d "$inc_dir" ]] || {
        echo "Error: [NSY_G68] 找不到 generic/files 目录" >&2
        return 1
    }

    # rtl8367b.c: 完整 RTL8367S 支持 (SGMII/HSGMII extif, LED 低有效等)
    \cp -f "$NSY_G68_ASSETS/driver/rtl8367b.c" "$phy_dir/rtl8367b.c"

    # rtl8366_smi.c: VIKINGYFY 6.18 版本 + rwbt/rdbt/rwbts/rdbts 位操作
    \cp -f "$NSY_G68_ASSETS/driver/rtl8366_smi.c" "$phy_dir/rtl8366_smi.c"

    # include/linux/rtl8367.h: 增加 RTL8367S 速度/模式枚举
    \cp -f "$NSY_G68_ASSETS/driver/rtl8367.h" "$inc_dir/rtl8367.h"

    # include/linux/switch.h: 增加 SWITCH_PORT_SPEED_2500
    \cp -f "$NSY_G68_ASSETS/driver/switch.h" "$inc_dir/switch.h"

    echo "  [驱动] 已更新 rtl8367b/rtl8366_smi 驱动与内核头文件 (RTL8367S SGMII)"
}

# 5. 板级网络配置: 02_network + 40-net-smp-affinity
inject_nsy_g68_board_files() {
    local base_files="$BUILD_DIR/target/linux/rockchip/armv8/base-files"
    local net_file="$base_files/etc/board.d/02_network"
    local smp_file="$base_files/etc/hotplug.d/net/40-net-smp-affinity"

    [[ -f "$net_file" ]] || {
        echo "Error: [NSY_G68] 找不到 02_network: $net_file" >&2
        return 1
    }

    # 5a. 02_network: 第1个 esac 前插入接口定义, 第2个 esac 前插入 MAC 定义
    if ! grep -q "nsy,g68-plus)" "$net_file"; then
        awk '
            /^[[:space:]]*esac$/ && !int_done {
                print "\tnsy,g68-plus)"
                print "\t\tucidef_set_interfaces_lan_wan \"eth0\" \"eth1\""
                print "\t\tucidef_add_switch \"switch0\" \\"
                print "\t\t\t\"0:lan\" \"1:lan\" \"2:lan\" \"3:lan\" \"4:wan\" \"6u@eth0\" \"7u@eth1\""
                print "\t\t;;"
                int_done = 1
            }
            /^[[:space:]]*esac$/ && int_done && !mac_done {
                print "\tnsy,g68-plus)"
                print "\t\twan_mac=$(macaddr_generate_from_mmc_cid mmcblk0)"
                print "\t\tlan_mac=$(macaddr_add \"$wan_mac\" 1)"
                print "\t\t;;"
                mac_done = 1
            }
            { print }
        ' "$net_file" > "$net_file.tmp" && mv "$net_file.tmp" "$net_file"
        echo "  [板级] 已注入 02_network (接口/MAC)"
    fi

    # 5b. 40-net-smp-affinity: 末尾 esac 前插入 G68 条目
    if [[ -f "$smp_file" ]] && ! grep -q "nsy,g68-plus)" "$smp_file"; then
        awk '
            /^[[:space:]]*esac$/ && !smp_done {
                print "nsy,g68-plus)"
                print "\tset_interface_core 8 \"eth0\""
                print "\tset_interface_core 4 \"eth1\""
                print "\tset_interface_core 2 \"mt7915e\""
                print "\t;;"
                smp_done = 1
            }
            { print }
        ' "$smp_file" > "$smp_file.tmp" && mv "$smp_file.tmp" "$smp_file"
        echo "  [板级] 已注入 40-net-smp-affinity"
    fi
}

# 5c. MT7916 WiFi 校准数据: NSY G68 的 MT7916 eeprom 不在 efuse/flash 分区,
#      开源 mt76 驱动 probe 时 request_firmware("mt7916_eeprom.bin") 失败
#      -> sysfs fallback 30 秒超时 -> probe -12 (ENOMEM), WiFi 无法启动。
#      注入 zhoufuli 仓库提取的 mt7916_eeprom.bin (4096B, 含 MT7916 magic 0x7916)。
#      放置到 rockchip armv8 base-files 的 /lib/firmware/mediatek/ 随 rootfs 打包。
inject_nsy_g68_wifi_firmware() {
    local fw_dir="$BUILD_DIR/target/linux/rockchip/armv8/base-files/lib/firmware/mediatek"
    local eeprom_src="$NSY_G68_ASSETS/firmware/mt7916_eeprom.bin"

    [[ -f "$eeprom_src" ]] || {
        echo "Error: [NSY_G68] 缺少 mt7916_eeprom.bin 资产" >&2
        return 1
    }

    mkdir -p "$fw_dir"
    \cp -f "$eeprom_src" "$fw_dir/mt7916_eeprom.bin"
    echo "  [WiFi] 已注入 mt7916_eeprom.bin ($(stat -c%s "$eeprom_src")B) -> /lib/firmware/mediatek/"
}
