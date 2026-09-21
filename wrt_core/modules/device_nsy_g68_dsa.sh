#!/usr/bin/env bash
# NSY G68-PLUS (DSA 变体) 设备支持注入模块
#
# 背景: 与 device_nsy_g68.sh (swconfig/rtl8367b) 同设备的 DSA 方案:
# 使用内核原生 rtl8365mb DSA 驱动替代 swconfig rtl8367b 私有驱动。
# VIKINGYFY/immortalwrt 6.18 内核已具备:
#   - rtl8365mb 芯片表含 RTL8367S (0x6367/0x00A0) [942-04 补丁自带]
#   - RTL8367S SGMII/HSGMII SerDes PCS [943-01/02]
#   - rockchip armv8 config 已内建 CONFIG_NET_DSA_REALTEK_RTL8365MB=y
# 因此无需注入任何内核驱动补丁, 仅注入设备支持:
#   1. 内核 DTS 补丁 (DSA 绑定: switch@29 + ports 双CPU口, 同时服务 U-Boot OF_UPSTREAM)
#   2. rockchip image 设备定义 (armv8.mk, 独立设备名 nsy_g68-plus-dsa)
#   3. U-Boot: 独立 defconfig + u-boot.dtsi + Makefile 设备定义
#   4. 板级网络配置: 02_network (DSA 接口) + 40-net-smp-affinity
#
# 资产目录: wrt_core/patches/nsy_g68_dsa/
# 开关: DEV_NAME=="NSY_G68_dsa" (由 update.sh 第 5 参传入)

NSY_G68_DSA_ASSETS="$SCRIPT_DIR/patches/nsy_g68_dsa"

# 入口: 由 update.sh stage_pre_install_source_fixes 调用。
add_nsy_g68_dsa_device_support() {
    [[ "$DEV_NAME" == "NSY_G68_dsa" ]] || return 0

    echo "==> [NSY_G68_DSA] 注入 nsy-g68-plus-dsa 设备支持 (DSA/rtl8365mb)"

    [[ -d "$BUILD_DIR/target/linux/rockchip" ]] || {
        echo "Error: [NSY_G68_DSA] 找不到 rockchip target 目录: $BUILD_DIR/target/linux/rockchip" >&2
        return 1
    }
    [[ -f "$NSY_G68_DSA_ASSETS/kernel/900-nsy-g68-dsa-arm64-boot-add-dts.patch" ]] || {
        echo "Error: [NSY_G68_DSA] 缺少内核 DTS 补丁资产" >&2
        return 1
    }

    inject_nsy_g68_dsa_kernel_dts
    inject_nsy_g68_dsa_image_def
    inject_nsy_g68_dsa_uboot
    inject_nsy_g68_dsa_board_files
    inject_nsy_g68_dsa_userdata_partition

    echo "==> [NSY_G68_DSA] 设备支持注入完成"
}

# 移植 zhoufuli 的 USERDATA 机制: G68 eMMC 为 256GB, OpenWrt 默认会把剩余空间
# 全部扩展为 overlay; 这里给镜像增加第三个分区 (ext4, 卷标 rootfs_data, 固定 2048MiB),
# OpenWrt 按卷标将其挂载为 overlay, 剩余空间保持未分配。
inject_nsy_g68_dsa_userdata_partition() {
    local script="$BUILD_DIR/scripts/gen_image_generic.sh"
    [[ -f "$script" ]] || {
        echo "Error: [NSY_G68_DSA] 找不到 $script" >&2
        return 1
    }

    python3 - "$script" <<'PYEOF'
import sys
path = sys.argv[1]
s = open(path).read()
if 'USERDATASIZE' in s:
    print('  [板级] gen_image_generic.sh 已含 USERDATA 分区, 跳过')
    sys.exit(0)
orig = s
# 1) 定义 USERDATA 大小 (固定 2048MiB, 与 zhoufuli NSY 固件一致)
s = s.replace('ALIGN="$6"', 'ALIGN="$6"\nUSERDATASIZE="${USERDATASIZE:-2048}"', 1)
# 2) ptgen 增加第三个分区 (rootfs_data)
s = s.replace('-p "${ROOTFSSIZE}m"',
              '-p "${ROOTFSSIZE}m" -t "${ROOTFSPARTTYPE}" -p "${USERDATASIZE}m"', 1)
# 3) 解析第三分区 offset/size (ptgen 输出 $5/$6, 均为字节)
s = s.replace('ROOTFSOFFSET="$(($3 / 512))"\nROOTFSSIZE="$(($4 / 512))"',
              'ROOTFSOFFSET="$(($3 / 512))"\nROOTFSSIZE="$(($4 / 512))"\n'
              'USERDATAOFFSET="$(($5 / 512))"\nUSERDATASIZE="$6"', 1)
# 4) rootfs 写入后, 生成 ext4 rootfs_data 并写入第三分区
s = s.replace('dd if="$ROOTFSIMAGE" of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc\n',
              'dd if="$ROOTFSIMAGE" of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc\n\n'
              'make_ext4fs -J -L rootfs_data -l "$USERDATASIZE" "$OUTPUT.rootfs_data"\n'
              'dd if="$OUTPUT.rootfs_data" of="$OUTPUT" bs=512 seek="$USERDATAOFFSET" conv=notrunc\n'
              'rm -f "$OUTPUT.rootfs_data"\n', 1)
if s == orig:
    print('Error: gen_image_generic.sh 替换未生效, 脚本结构可能已变化', file=sys.stderr)
    sys.exit(1)
open(path, 'w').write(s)
print('  [板级] 已注入 gen_image_generic.sh: rootfs_data 第三分区 (2048MiB, 卷标 rootfs_data)')
PYEOF
}

# 1. 内核 DTS: 将自包含补丁放入 target/linux/rockchip/patches-<ver>/
inject_nsy_g68_dsa_kernel_dts() {
    local patch_dir
    local patch_name="900-nsy-g68-dsa-arm64-boot-add-dts.patch"

    patch_dir=$(ls -d "$BUILD_DIR"/target/linux/rockchip/patches-* 2>/dev/null | sort -V | tail -1)
    [[ -n "$patch_dir" && -d "$patch_dir" ]] || {
        echo "Error: [NSY_G68_DSA] 找不到内核 patches 目录" >&2
        return 1
    }

    if [[ ! -f "$patch_dir/$patch_name" ]]; then
        install -m644 "$NSY_G68_DSA_ASSETS/kernel/$patch_name" "$patch_dir/$patch_name"
        echo "  [内核] 已安装 DSA DTS 补丁 -> $patch_dir/$patch_name"
    fi
}

# 2. 镜像定义: 向 armv8.mk 追加 Device/nsy_g68-plus-dsa
inject_nsy_g68_dsa_image_def() {
    local armv8_mk="$BUILD_DIR/target/linux/rockchip/image/armv8.mk"
    local marker="Device/nsy_g68-plus-dsa"

    [[ -f "$armv8_mk" ]] || {
        echo "Error: [NSY_G68_DSA] 找不到 armv8.mk: $armv8_mk" >&2
        return 1
    }

    if ! grep -q "$marker" "$armv8_mk"; then
        cat >> "$armv8_mk" <<'EOF'

# ============ NSY G68-PLUS DSA (由 device_nsy_g68_dsa.sh 注入) ============
define Device/nsy_g68-plus-dsa
  $(Device/rk3568)
  DEVICE_VENDOR := NSY
  DEVICE_MODEL := G68-PLUS (DSA)
  DEVICE_DTS := rk3568-nsy-g68-plus-dsa
  UBOOT_DEVICE_NAME := nsy-g68-plus-dsa-rk3568
  DEVICE_PACKAGES := kmod-mt7916-firmware wpad-openssl
endef
TARGET_DEVICES += nsy_g68-plus-dsa
EOF
        echo "  [镜像] 已追加 Device/nsy_g68-plus-dsa -> $armv8_mk"
    fi
}

# 3. U-Boot: 独立 defconfig + u-boot.dtsi + Makefile 定义
inject_nsy_g68_dsa_uboot() {
    local uboot_dir="$BUILD_DIR/package/boot/uboot-rockchip"
    local uboot_mk="$uboot_dir/Makefile"

    [[ -d "$uboot_dir" ]] || {
        echo "Error: [NSY_G68_DSA] 找不到 uboot-rockchip 包: $uboot_dir" >&2
        return 1
    }

    # 3a. defconfig (DEFAULT_DEVICE_TREE 指向 DSA dts)
    if [[ ! -f "$uboot_dir/src/configs/nsy-g68-plus-dsa-rk3568_defconfig" ]]; then
        install -Dm644 "$NSY_G68_DSA_ASSETS/uboot/nsy-g68-plus-dsa-rk3568_defconfig" \
            "$uboot_dir/src/configs/nsy-g68-plus-dsa-rk3568_defconfig"
        echo "  [U-Boot] 已安装 DSA defconfig"
    fi

    # 3b. u-boot.dtsi (U-Boot 从 arch/arm/dts/ 顶层查找 *-u-boot.dtsi)
    if [[ ! -f "$uboot_dir/src/arch/arm/dts/rk3568-nsy-g68-plus-dsa-u-boot.dtsi" ]]; then
        install -Dm644 "$NSY_G68_DSA_ASSETS/uboot/rk3568-nsy-g68-plus-dsa-u-boot.dtsi" \
            "$uboot_dir/src/arch/arm/dts/rk3568-nsy-g68-plus-dsa-u-boot.dtsi"
        echo "  [U-Boot] 已安装 DSA u-boot.dtsi (arch/arm/dts/)"
    fi

    # 3c. Makefile 设备定义
    if ! grep -q "nsy-g68-plus-dsa-rk3568" "$uboot_mk"; then
        awk '
            /^\$\(eval \$\(call BuildPackage\/U-Boot\)\)/ && !done {
                print "define U-Boot/nsy-g68-plus-dsa-rk3568"
                print "  $(U-Boot/rk3568/Default)"
                print "  NAME:=NSY G68 PLUS (DSA)"
                print "  BUILD_DEVICES:= \\"
                print "    nsy_g68-plus-dsa"
                print "endef"
                print ""
                done = 1
            }
            { print }
        ' "$uboot_mk" > "$uboot_mk.tmp" && mv "$uboot_mk.tmp" "$uboot_mk"
        echo "  [U-Boot] 已注册 U-Boot/nsy-g68-plus-dsa-rk3568"
    fi

    # 3d. 加入 UBOOT_TARGETS 构建列表 (OpenWrt 只构建列表内的 U-Boot 设备)
    if ! grep -q "^  nsy-g68-plus-dsa-rk3568" "$uboot_mk"; then
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
lines.insert(last_item + 1, '  nsy-g68-plus-dsa-rk3568')
open(path, 'w').write('\n'.join(lines))
print('  [U-Boot] 已加入 UBOOT_TARGETS: nsy-g68-plus-dsa-rk3568')
PYEOF
    fi

    # 3e. OF_UPSTREAM DTS: U-Boot 2026.07 默认从 dts/upstream 编译设备树。
    # 内核 DTS 基于 6.18 (含 &xpcs 节点), 但 U-Boot 快照 (rk3568.dtsi) 无 xpcs,
    # 生成 U-Boot 专用 DTS: 去掉 &xpcs 引用 (U-Boot 不需要 PCS 配置)。
    local upstream_dts_dir="$uboot_dir/src/dts/upstream/src/arm64/rockchip"
    mkdir -p "$upstream_dts_dir"
    if [[ ! -f "$upstream_dts_dir/rk3568-nsy-g68-plus-dsa.dts" ]]; then
        python3 - "$NSY_G68_DSA_ASSETS/kernel/rk3568-nsy-g68-plus-dsa.dts" \
            "$upstream_dts_dir/rk3568-nsy-g68-plus-dsa.dts" <<'PYEOF'
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
    print('Warning: DSA DTS 未找到 xpcs 引用, 可能结构已变', file=sys.stderr)
open(dst, 'w').write(s2)
print('  [U-Boot] 已生成 U-Boot 版 DSA DTS (去掉 &xpcs)')
PYEOF
    fi
}

# 4. 板级网络配置: 02_network (DSA 接口) + 40-net-smp-affinity
inject_nsy_g68_dsa_board_files() {
    local base_files="$BUILD_DIR/target/linux/rockchip/armv8/base-files"
    local net_file="$base_files/etc/board.d/02_network"
    local smp_file="$base_files/etc/hotplug.d/net/40-net-smp-affinity"

    [[ -f "$net_file" ]] || {
        echo "Error: [NSY_G68_DSA] 找不到 02_network: $net_file" >&2
        return 1
    }

    # 4a. 02_network: 第1个 esac 前插入接口定义, 第2个 esac 前插入 MAC 定义
    if ! grep -q "nsy,g68-plus-dsa" "$net_file"; then
        awk '
            /^[[:space:]]*esac$/ && !int_done {
                print "\tnsy,g68-plus-dsa)"
                print "\t\tucidef_set_interfaces_lan_wan \"lan1 lan2 lan3 lan4\" \"wan\""
                print "\t\t;;"
                int_done = 1
            }
            /^[[:space:]]*esac$/ && int_done && !mac_done {
                print "\tnsy,g68-plus-dsa)"
                print "\t\twan_mac=$(macaddr_generate_from_mmc_cid mmcblk0)"
                print "\t\tlan_mac=$(macaddr_add \"$wan_mac\" 1)"
                print "\t\t;;"
                mac_done = 1
            }
            { print }
        ' "$net_file" > "$net_file.tmp" && mv "$net_file.tmp" "$net_file"
        echo "  [板级] 已注入 02_network (DSA 接口/MAC)"
    fi

    # 4b. 40-net-smp-affinity: 末尾 esac 前插入条目
    if [[ -f "$smp_file" ]] && ! grep -q "nsy,g68-plus-dsa" "$smp_file"; then
        awk '
            /^[[:space:]]*esac$/ && !smp_done {
                print "nsy,g68-plus-dsa)"
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
