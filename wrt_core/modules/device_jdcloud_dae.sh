#!/usr/bin/env bash
# jdcloud_ipq60xx_immwrt_dae 专用: 内核大小补丁模块
#
# 背景: 原先为把 jdcloud_re-cs-02 / jdcloud_re-ss-01 的 KERNEL_SIZE
# 从 6144k 改成 12288k 而维护了 fork 源码 (langcunfu/VIKINGYFY-immortalwrt)。
# 现改回上游 VIKINGYFY/immortalwrt, 该改动改为构建时打补丁应用, 不再 fork。
#
# 补丁只命中这两个设备块的 KERNEL_SIZE; 同文件内其它设备
# (jdcloud_re-cs-07 / link_nn6000-common 等) 的 6144k 保持原样。
# 仅在 DEV_NAME == jdcloud_ipq60xx_immwrt_dae 时生效, 不影响其它设备。

JDCLOUD_DAE_ASSETS="$SCRIPT_DIR/patches/jdcloud_dae"

# 入口: 由 update.sh stage_pre_install_source_fixes 调用。
add_jdcloud_dae_kernel_size_patch() {
    [[ "$DEV_NAME" == "jdcloud_ipq60xx_immwrt_dae" ]] || return 0

    local mk="$BUILD_DIR/target/linux/qualcommax/image/ipq60xx.mk"
    local patch="$JDCLOUD_DAE_ASSETS/ipq60xx-kernel-size.patch"

    [[ -f "$mk" ]] || {
        echo "Error: [jdcloud-dae] 找不到 ipq60xx.mk: $mk" >&2
        return 1
    }
    [[ -f "$patch" ]] || {
        echo "Error: [jdcloud-dae] 缺少补丁资产: $patch" >&2
        return 1
    }

    # 幂等: 两个目标设备块均已是 12288k 则视为已应用, 跳过。
    local cs02_size ss01_size
    cs02_size=$(awk '/^define Device\/jdcloud_re-cs-02$/{f=1} f&&/KERNEL_SIZE/{print $3; exit}' "$mk")
    ss01_size=$(awk '/^define Device\/jdcloud_re-ss-01$/{f=1} f&&/KERNEL_SIZE/{print $3; exit}' "$mk")

    if [[ "$cs02_size" == "12288k" && "$ss01_size" == "12288k" ]]; then
        echo "==> [jdcloud-dae] KERNEL_SIZE 补丁已应用, 跳过"
        return 0
    fi

    echo "==> [jdcloud-dae] 应用 KERNEL_SIZE 补丁 (cs-02 / ss-01: 6144k -> 12288k)"
    (cd "$BUILD_DIR" && patch -p1 --forward --no-backup-if-mismatch -s < "$patch") || {
        echo "Error: [jdcloud-dae] KERNEL_SIZE 补丁应用失败, 请检查 ipq60xx.mk 是否与上游结构一致" >&2
        return 1
    }

    # 应用后复核: 两处必须为 12288k
    cs02_size=$(awk '/^define Device\/jdcloud_re-cs-02$/{f=1} f&&/KERNEL_SIZE/{print $3; exit}' "$mk")
    ss01_size=$(awk '/^define Device\/jdcloud_re-ss-01$/{f=1} f&&/KERNEL_SIZE/{print $3; exit}' "$mk")
    if [[ "$cs02_size" != "12288k" || "$ss01_size" != "12288k" ]]; then
        echo "Error: [jdcloud-dae] 补丁复核失败: cs-02=$cs02_size ss-01=$ss01_size (应为 12288k)" >&2
        return 1
    fi
    echo "==> [jdcloud-dae] KERNEL_SIZE 补丁应用完成 (cs-02=$cs02_size ss-01=$ss01_size)"
}
