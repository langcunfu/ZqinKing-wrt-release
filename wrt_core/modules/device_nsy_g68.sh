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

    echo "==> [NSY_G68] 设备支持注入完成"
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
}

# 2. 镜像定义: 向 armv8.mk 追加 Device/nsy_g68-plus
inject_nsy_g68_image_def() {
    local armv8_mk="$BUILD_DIR/target/linux/rockchip/image/armv8.mk"
    local marker="Device/nsy_g68-plus"

    [[ -f "$armv8_mk" ]] || {
        echo "Error: [NSY_G68] 找不到 armv8.mk: $armv8_mk" >&2
        return 1
    }

    if ! grep -q "$marker" "$armv8_mk"; then
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

    # 3b. u-boot.dtsi (OF_UPSTREAM 专用覆盖: eMMC HS400)
    if [[ ! -f "$uboot_dir/src/arch/arm/dts/rockchip/rk3568-nsy-g68-plus-u-boot.dtsi" ]]; then
        install -Dm644 "$NSY_G68_ASSETS/uboot/rk3568-nsy-g68-plus-u-boot.dtsi" \
            "$uboot_dir/src/arch/arm/dts/rockchip/rk3568-nsy-g68-plus-u-boot.dtsi"
        echo "  [U-Boot] 已安装 u-boot.dtsi"
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
    if ! grep -q "nsy,g68-plus" "$net_file"; then
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
    if [[ -f "$smp_file" ]] && ! grep -q "nsy,g68-plus" "$smp_file"; then
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
