#!/bin/sh
# 首次启动 (uci-defaults): 设置时区 + 安装 USB 自动挂载 hotplug 脚本。
# 生成 /etc/hotplug.d/block/99-usb-utf8sda1, USB 存储插入时自动挂载到 /mnt/sdaX。

uci -q batch <<-EOF
	set system.@system[0].timezone="CST-8"
	set system.@system[0].zonename="Asia/Shanghai"
	commit system
EOF

mkdir -p /etc/hotplug.d/block
cat > /etc/hotplug.d/block/99-usb-utf8sda1 <<'USBEOF'
#!/bin/sh

if [ "$ACTION" = "add" ]; then
    # 只处理 sd 类设备
    if echo "$DEVNAME" | grep -qE '^sd[a-z]$|^sd[a-z][0-9]$'; then
        DEV="/dev/$DEVNAME"

        # ==============================================
        # 智能挂载逻辑：
        # 1. 统计当前已挂载的 sd 分区数量
        # 2. 只有 1 个 -> 强制挂载到 /mnt/sda1
        # 3. 多个 -> 按 sda1/sda2/sda3... 自动分配
        # ==============================================
        MOUNTED_COUNT=$(mount | grep -E '^/dev/sd[a-z][0-9]' | wc -l)

        if [ "$MOUNTED_COUNT" -eq 0 ]; then
            # 当前无任何挂载 -> 第一个设备，强制固定到 /mnt/sda1
            MNT="/mnt/sda1"
        else
            # 已有挂载 -> 按顺序自动分配 sda1、sda2、sda3...
            INDEX=$((MOUNTED_COUNT + 1))
            MNT="/mnt/sda$INDEX"
        fi

        # 创建挂载目录
        mkdir -p "$MNT"

        # 获取文件系统类型
        FSTYPE=$(blkid "$DEV" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')

        # 分格式挂载
        case "$FSTYPE" in
            ntfs)
                mount -t ntfs "$DEV" "$MNT" -o noatime,nodiratime,iocharset=utf8,force,sync 2>/dev/null
                ;;
            ext4)
                mount -t ext4 "$DEV" "$MNT" -o noatime,nodiratime,sync 2>/dev/null
                ;;
            exfat|vfat)
                mount -t auto "$DEV" "$MNT" -o noatime,nodiratime,iocharset=utf8,sync 2>/dev/null
                ;;
            *)
                mount -t auto "$DEV" "$MNT" -o noatime,nodiratime,sync 2>/dev/null
                ;;
        esac
    fi
fi

# ==============================================
# 自动清理 /mnt 下所有空的、未挂载的目录
# 保护 /mnt/tmp，永远不删除
# ==============================================
for dir in /mnt/*/; do
    [ -d "$dir" ] || continue
    # 跳过 /mnt/tmp 目录，不删除
    [ "$dir" = "/mnt/tmp/" ] && continue

    if [ -z "$(ls -A "$dir" 2>/dev/null)" ] && ! mountpoint -q "$dir"; then
        rmdir "$dir" 2>/dev/null
    fi
done
USBEOF
chmod 755 /etc/hotplug.d/block/99-usb-utf8sda1

exit 0
