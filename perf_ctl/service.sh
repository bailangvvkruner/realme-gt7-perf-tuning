#!/system/bin/sh
# 开机服务: 1) 确保 chp 被遮蔽(补 post-fs-data 未覆盖的情况) 2) 兜底关掉 zram1 3) 可选应用性能配置
MODDIR=${0%/*}
LOG=/data/adb/perf_ctl.log
CONF=/data/adb/perf_ctl.conf
log() { echo "[$(date '+%m-%d %H:%M:%S')] [svc] $1" >> "$LOG"; }

log "===== service start ====="

# ---------- 1. chp 遮蔽 ----------
mask_chp() {
  chp=/sys/kernel/mm/chp
  [ -d "$chp" ] || return 1
  mountpoint -q "$chp" 2>/dev/null && return 0
  mount -t tmpfs -o size=64k,mode=0555 tmpfs "$chp" 2>/dev/null || return 1
  return 0
}

if ! mask_chp; then
  # chp 可能在启动稍后才由驱动创建, 最多等 90s
  i=0
  while [ $i -lt 90 ]; do
    if mask_chp; then log "chp 延迟遮蔽成功 (${i}s)"; break; fi
    sleep 1
    i=$((i+1))
  done
  [ $i -ge 90 ] && log "chp 遮蔽未生效"
else
  log "chp 已在 post-fs-data 阶段遮蔽"
fi

# ---------- 2. 等 boot 完成后兜底清 zram1 ----------
i=0
while [ $i -lt 150 ]; do
  [ "$(getprop sys.boot_completed)" = "1" ] && break
  sleep 1
  i=$((i+1))
done
sleep 12

if [ -e /sys/block/zram1 ]; then
  z1=$(cat /sys/block/zram1/disksize 2>/dev/null)
  if [ -n "$z1" ] && [ "$z1" != "0" ]; then
    # swap 操作必须用 /dev/block/zram1 (/sys/block/zram1 是符号链接目录)
    swapoff /dev/block/zram1 2>/dev/null
    echo 1 > /sys/block/zram1/reset 2>/dev/null
    log "兜底: zram1 已关闭 (原 disksize=$z1)"
  fi
fi

# ---------- 3. 性能配置 ----------
AUTO_ON_BOOT=0
OIFACE_OFF=0
ACTIVE=0
[ -f "$CONF" ] && . "$CONF"

if [ "$AUTO_ON_BOOT" = "1" ] && [ "$ACTIVE" = "1" ]; then
  [ "$OIFACE_OFF" = "1" ] && { stop oiface 2>/dev/null; sleep 1; }
  sh "$MODDIR/scripts/ctl.sh" apply >/dev/null 2>&1
  log "已应用性能配置 (oiface_off=$OIFACE_OFF)"
else
  log "开机不自动应用性能配置 (auto_boot=$AUTO_ON_BOOT active=$ACTIVE)"
fi

# 守护常驻: 仅当 ACTIVE=1 时修正漂移, 否则空转(5s 读一次, 开销可忽)
sh "$MODDIR/scripts/ctl.sh" dstart >/dev/null 2>&1
log "守护已启动"
