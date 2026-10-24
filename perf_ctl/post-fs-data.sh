#!/system/bin/sh
# 开机最早阶段: 遮蔽 /sys/kernel/mm/chp, 阻止 OPPO nandswap 创建 8.5GB zram1
# 依据: /product/bin/init.oplus.nandswap.sh 用 [ -e /sys/kernel/mm/chp/enabled ] 判定 chp_supported
MODDIR=${0%/*}
LOG=/data/adb/perf_ctl.log
log() { echo "[$(date '+%m-%d %H:%M:%S')] [pfd] $1" >> "$LOG"; }

mkdir -p "$LOG" 2>/dev/null
chp=/sys/kernel/mm/chp
if [ -d "$chp" ]; then
  if ! mountpoint -q "$chp" 2>/dev/null; then
    mount -t tmpfs -o size=64k,mode=0555 tmpfs "$chp" 2>/dev/null \
      && log "chp 已用 tmpfs 遮蔽 -> chp_supported=0" \
      || log "chp 遮蔽失败"
  else
    log "chp 已是挂载点, 跳过"
  fi
else
  log "chp 目录不存在"
fi
