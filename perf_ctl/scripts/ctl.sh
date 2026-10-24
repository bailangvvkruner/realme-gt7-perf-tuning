#!/system/bin/sh
# perf_ctl 核心控制脚本
# 唯一可靠路径: 停 oiface -> 写 scaling_max_freq / scaling_min_freq
# uclamp (sched_util_clamp_max) 在 ColorOS15/MT6989 上写入即被内核重置为 1024, 已弃用

CONF=/data/adb/perf_ctl.conf
LOG=/data/adb/perf_ctl.log
PIDF=/data/adb/perf_ctl.pid

log() { echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG"; }

AP0=/sys/devices/system/cpu/cpufreq/policy0
AP4=/sys/devices/system/cpu/cpufreq/policy4
AP7=/sys/devices/system/cpu/cpufreq/policy7
GPU_UP=/sys/module/ged/parameters/gpu_cust_upbound_freq
GPU_BOTTOM=/sys/module/ged/parameters/gpu_bottom_freq
ULMAX=/proc/sys/kernel/sched_util_clamp_max
ULMIN=/proc/sys/kernel/sched_util_clamp_min

apath() { case "$1" in 0) echo $AP0;; 4) echo $AP4;; 7) echo $AP7;; esac; }

# policy7 标称 3400MHz 但内核实际最高只接受 3250MHz
usable_max() {
  case "$1" in
    0) echo $(cat $AP0/cpuinfo_max_freq) ;;
    4) echo $(cat $AP4/cpuinfo_max_freq) ;;
    7) v=$(cat $AP7/cpuinfo_max_freq)
       [ "$v" -gt 3250000 ] 2>/dev/null && v=3250000
       echo "$v" ;;
  esac
}
hw_min() { cat $(apath $1)/cpuinfo_min_freq 2>/dev/null; }

load_conf() {
  P0_MAX=2000000; P0_MIN=300000
  P4_MAX=2300000; P4_MIN=550000
  P7_MAX=2500000; P7_MIN=600000
  GPU_IDX=24
  GPU_BOTTOM_KHZ=130000
  UCLAMP_MAX=1024
  OIFACE_OFF=0
  AUTO_ON_BOOT=0
  ACTIVE=0
  GOV=sugov_ext
  [ -f "$CONF" ] && . "$CONF"
}

save_conf() {
  cat > "$CONF" <<EOF
P0_MAX=$P0_MAX
P0_MIN=$P0_MIN
P4_MAX=$P4_MAX
P4_MIN=$P4_MIN
P7_MAX=$P7_MAX
P7_MIN=$P7_MIN
GPU_IDX=$GPU_IDX
GPU_BOTTOM_KHZ=$GPU_BOTTOM_KHZ
UCLAMP_MAX=$UCLAMP_MAX
OIFACE_OFF=$OIFACE_OFF
AUTO_ON_BOOT=$AUTO_ON_BOOT
ACTIVE=$ACTIVE
GOV=$GOV
EOF
  chmod 644 "$CONF" 2>/dev/null
}

oiface_state() { getprop init.svc.oiface 2>/dev/null; }

oiface_stop() {
  [ "$(oiface_state)" = "running" ] || return 0
  stop oiface 2>/dev/null
  # 等 init 回收
  i=0; while [ $i -lt 10 ]; do
    [ "$(oiface_state)" = "running" ] || break
    sleep 0.3; i=$((i+1))
  done
  log "oiface stopped -> $(oiface_state)"
}

oiface_start() {
  [ "$(oiface_state)" = "running" ] && return 0
  start oiface 2>/dev/null
  i=0; while [ $i -lt 15 ]; do
    [ "$(oiface_state)" = "running" ] && break
    sleep 0.3; i=$((i+1))
  done
  log "oiface started -> $(oiface_state)"
}

# 设置单集群: 处理 min/max 交叉约束
set_cluster() {
  c=$1; nmax=$2; nmin=$3
  d=$(apath $c)
  hwM=$(usable_max $c); hwm=$(hw_min $c)

  [ -n "$nmax" ] && [ "$nmax" -gt "$hwM" ] 2>/dev/null && nmax=$hwM
  [ -n "$nmin" ] && [ "$nmin" -lt "$hwm" ] 2>/dev/null && nmin=$hwm
  [ -n "$nmin" ] && [ -n "$nmax" ] && [ "$nmin" -gt "$nmax" ] 2>/dev/null && nmin=$nmax

  fmax=$d/scaling_max_freq; fmin=$d/scaling_min_freq
  chmod 644 "$fmax" "$fmin" 2>/dev/null

  cmin=$(cat "$fmin" 2>/dev/null)
  # 若新上限低于当前下限, 必须先降下限, 否则写 max 会被 EINVAL 拒绝
  if [ -n "$cmin" ] && [ "$nmax" -lt "$cmin" ] 2>/dev/null; then
    echo "$nmin" > "$fmin" 2>/dev/null
  fi
  echo "$nmax" > "$fmax" 2>/dev/null
  [ -n "$nmin" ] && echo "$nmin" > "$fmin" 2>/dev/null
}

apply_cpu() {
  set_cluster 0 "$P0_MAX" "$P0_MIN"
  set_cluster 4 "$P4_MAX" "$P4_MIN"
  set_cluster 7 "$P7_MAX" "$P7_MIN"
}

apply_gpu() {
  echo "$GPU_IDX" > "$GPU_UP" 2>/dev/null
  [ -n "$GPU_BOTTOM_KHZ" ] && echo "$GPU_BOTTOM_KHZ" > "$GPU_BOTTOM" 2>/dev/null
}

# uclamp: 内核强制 min <= max，否则 proc handler 返回 EINVAL 直接拒写
# （这就是旧结论“uclamp 写入无效”的真正原因，不是内核丢弃）
set_uclamp() {
  want=$1
  [ -z "$want" ] && return 0
  [ "$want" -lt 0 ] 2>/dev/null && want=0
  [ "$want" -gt 1024 ] 2>/dev/null && want=1024
  cmin=$(cat "$ULMIN" 2>/dev/null)
  [ -z "$cmin" ] && cmin=0
  # 若现有下限高于目标上限，必须先把下限压下去，否则写 max 会被 EINVAL 拒绝
  if [ "$want" -lt "$cmin" ] 2>/dev/null; then
    echo 0 > "$ULMIN" 2>/dev/null
  fi
  echo "$want" > "$ULMAX" 2>/dev/null
}

upl() { echo "$(cat $ULMIN 2>/dev/null)/$(cat $ULMAX 2>/dev/null)"; }

set_governor() {
  for c in 0 4 7; do
    d=$(apath $c)
    chmod 644 "$d/scaling_governor" 2>/dev/null
    echo "$GOV" > "$d/scaling_governor" 2>/dev/null
  done
}

rd() { cat "$(apath $1)/$2" 2>/dev/null; }

fgn() {
  dumpsys window 2>/dev/null | grep -m1 mFocusedApp \
    | sed -e 's/.*u0 //' -e 's/[ }].*//' | cut -d/ -f1
}

cmd_status() {
  load_conf
  echo "oiface=$(oiface_state)"
  echo "cfg_oiface_off=$OIFACE_OFF"
  echo "cfg_auto_boot=$AUTO_ON_BOOT"
  echo "cfg_active=$ACTIVE"
  echo "cfg_gov=$GOV"
  for c in 0 4 7; do
    echo "p${c}_cur=$(rd $c scaling_cur_freq)"
    echo "p${c}_max=$(rd $c scaling_max_freq)"
    echo "p${c}_min=$(rd $c scaling_min_freq)"
    echo "p${c}_hwmax=$(usable_max $c)"
    echo "p${c}_hwmin=$(hw_min $c)"
    echo "p${c}_cfg_max=$(eval echo \$P${c}_MAX)"
    echo "p${c}_cfg_min=$(eval echo \$P${c}_MIN)"
  done
  echo "gov=$(rd 7 scaling_governor)"
  echo "gpu_idx=$(cat $GPU_UP 2>/dev/null)"
  echo "gpu_cur=$(cat /sys/kernel/ged/hal/current_freqency 2>/dev/null)"
  echo "gpu_bottom=$(cat $GPU_BOTTOM 2>/dev/null)"
  echo "cfg_gpu_idx=$GPU_IDX"
  echo "cfg_gpu_bottom=$GPU_BOTTOM_KHZ"
  echo "uclamp_min=$(cat $ULMIN 2>/dev/null)"
  echo "uclamp_max=$(cat $ULMAX 2>/dev/null)"
  echo "uclamp_eff_max=$(grep -m1 'effective uclamp.max' /proc/self/sched 2>/dev/null | awk '{print $NF}')"
  echo "cfg_uclamp_max=$UCLAMP_MAX"
  echo "t_big=$(cat /sys/class/thermal/thermal_zone20/temp 2>/dev/null)"
  echo "t_med=$(cat /sys/class/thermal/thermal_zone14/temp 2>/dev/null)"
  echo "t_little=$(cat /sys/class/thermal/thermal_zone10/temp 2>/dev/null)"
  echo "t_soc=$(cat /sys/class/thermal/thermal_zone26/temp 2>/dev/null)"
  echo "t_batt=$(cat /sys/class/thermal/thermal_zone8/temp 2>/dev/null)"
  echo "batt=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
  echo "loadavg=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
  echo "fg=$(fgn)"
  echo "swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  echo "zram0=$(cat /sys/block/zram0/disksize 2>/dev/null)"
  echo "zram1=$(cat /sys/block/zram1/disksize 2>/dev/null)"
}

cmd_apply() {
  load_conf
  [ -n "$1" ] && P0_MAX=$1
  [ -n "$2" ] && P4_MAX=$2
  [ -n "$3" ] && P7_MAX=$3
  [ -n "$4" ] && GPU_IDX=$4
  # 第 5 参 oiface：1 = 停止；0/空 = 不改动（保留配置里记住的值）
  # 绝对不要用 0 去覆盖已有的 1，否则“停止 oiface”会被后续 apply 抹掉
  if [ "$5" = "1" ]; then OIFACE_OFF=1; fi
  [ -n "$6" ] && UCLAMP_MAX=$6

  # 只停不起：OIFACE_OFF=0 仅表示“不去碰它”，绝不主动 start
  # 否则用户手动停掉的 oiface 一按“应用配置”就又活过来（旧 bug）
  [ "$OIFACE_OFF" = "1" ] && oiface_stop
  apply_cpu
  set_uclamp "$UCLAMP_MAX"
  apply_gpu
  ACTIVE=1
  save_conf

  # 回读校验
  err=0
  for c in 0 4 7; do
    want=$(eval echo \$P${c}_MAX)
    um=$(usable_max $c)
    [ "$want" -gt "$um" ] 2>/dev/null && want=$um
    got=$(rd $c scaling_max_freq)
    [ "$got" = "$want" ] || err=1
  done
  ug=$(cat "$ULMAX" 2>/dev/null)
  [ "$ug" = "$UCLAMP_MAX" ] || err=1
  log "apply p0=$P0_MAX p4=$P4_MAX p7=$P7_MAX gpu=$GPU_IDX uclamp=$UCLAMP_MAX oiface_off=$OIFACE_OFF err=$err"
  cmd_daemon_start
  [ "$err" = "0" ] && echo "OK" || echo "PARTIAL"
}

# ---------- 守护: 检测漂移并修正 ----------
daemon_alive() {
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] && [ -d "/proc/$p" ] || return 1
  # 防止 pid 被复用时误判（cmdline 是 NUL 分隔）
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'ctl.sh daemon' && return 0
  return 1
}

dae_kill_all() {
  # 杀掉所有游离守护（双守护会互相覆盖配置，导致 reset 被改回）
  for p in $(ps -A -o PID,ARGS 2>/dev/null | grep 'ctl\.sh daemon' | grep -v grep | awk '{print $1}'); do
    [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null
  done
  rm -f "$PIDF"
  return 0
}

cmd_daemon_start() {
  daemon_alive && return 0
  dae_kill_all
  sh "$0" daemon >/dev/null 2>&1 &
  echo $! > "$PIDF"
  return 0
}

cmd_daemon_stop() {
  dae_kill_all
  log "daemon 已停止"
}

cmd_ensure() {
  load_conf
  [ "$ACTIVE" = "1" ] || return 0
  changed=0
  for c in 0 4 7; do
    d=$(apath $c)
    want=$(eval echo \$P${c}_MAX)
    um=$(usable_max $c)
    [ "$want" -gt "$um" ] 2>/dev/null && want=$um
    got=$(cat "$d/scaling_max_freq" 2>/dev/null)
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      set_cluster $c "$want" "$(eval echo \$P${c}_MIN)"
      changed=1
    fi
  done
  g=$(cat "$GPU_UP" 2>/dev/null)
  if [ -n "$g" ] && [ "$g" != "$GPU_IDX" ]; then
    echo "$GPU_IDX" > "$GPU_UP" 2>/dev/null
    changed=1
  fi
  u=$(cat "$ULMAX" 2>/dev/null)
  if [ -n "$u" ] && [ "$u" != "$UCLAMP_MAX" ]; then
    set_uclamp "$UCLAMP_MAX"
    changed=1
  fi
  [ "$changed" = "1" ] && log "ensure: 检测到漂移, 已修正"
  return 0
}

cmd_daemon() {
  # 双守护互杀：若已有另一个活着的守护，直接退出
  if [ -f "$PIDF" ]; then
    o=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$o" ] && [ "$o" != "$$" ] && [ -d "/proc/$o" ]; then
      exit 0
    fi
  fi
  echo $$ > "$PIDF"
  log "daemon 启动 pid=$$"
  while :; do
    # 模块被禁用/卸载则自杀，不留幽灵进程
    if [ -f /data/adb/modules/perf_ctl/disable ] || [ ! -d /data/adb/modules/perf_ctl ]; then
      log "daemon 退出：模块已禁用"
      rm -f "$PIDF"
      exit 0
    fi
    cmd_ensure
    sleep 5
  done
}

cmd_presets() {
  # 字段: id|名称|p0max|p4max|p7max|gpu_idx|oiface_off|uclamp_max
  # 依据第 9.6 章能效实测数据
  echo "save|省电|1200000|1400000|1400000|38|0|256"
  echo "balance|均衡|2000000|2300000|2500000|24|0|512"
  echo "stock|原厂|2000000|2300000|2500000|24|0|1024"
  echo "perf|性能|2000000|2600000|2900000|20|0|1024"
}

cmd_reset() {
  cmd_daemon_stop
  rm -f "$CONF"
  load_conf
  P0_MIN=$(hw_min 0); P4_MIN=$(hw_min 4); P7_MIN=$(hw_min 7)
  # 出厂态 = oiface 自己的目标值，不是硬件满频（实测满频纯浪费）
  P0_MAX=2000000; P4_MAX=2300000; P7_MAX=2500000
  GPU_IDX=24; GPU_BOTTOM_KHZ=130000; OIFACE_OFF=0
  # 恢复出厂 uclamp（先提 max 再提 min，避开 min<=max 校验）
  echo 1024 > "$ULMAX" 2>/dev/null
  echo 1024 > "$ULMIN" 2>/dev/null
  UCLAMP_MAX=1024
  oiface_start
  sleep 1
  apply_cpu; apply_gpu
  log "reset -> 出厂默认 p0=2000000 p4=2300000 p7=2500000 gpu=24 uclamp=1024/1024"
  echo "OK"
}

case "$1" in
  status)   cmd_status ;;
  apply)    shift; cmd_apply "$@" ;;
  governor) load_conf; GOV=${2:-sugov_ext}; set_governor; save_conf; echo OK ;;
  oiface)
    shift
    case "$1" in
      off)
        load_conf; OIFACE_OFF=1; save_conf
        oiface_stop
        echo "OK state=$(oiface_state)" ;;
      on)
        load_conf; OIFACE_OFF=0; save_conf
        oiface_start
        echo "OK state=$(oiface_state)" ;;
      *) echo "usage: $0 oiface {on|off}" ;;
    esac ;;
  reset)    cmd_reset ;;
  presets)  cmd_presets ;;
  setboot)  load_conf; AUTO_ON_BOOT=${2:-0}; save_conf; echo OK ;;
  uclamp)
    load_conf
    UCLAMP_MAX=${2:-1024}
    set_uclamp "$UCLAMP_MAX"
    save_conf
    [ "$(cat $ULMAX 2>/dev/null)" = "$UCLAMP_MAX" ] && echo OK || echo FAIL ;;
  ensure)   cmd_ensure ;;
  daemon)   cmd_daemon ;;
  dstart)   cmd_daemon_start; echo OK ;;
  dstop)    cmd_daemon_stop; echo OK ;;
  dstat)    daemon_alive && echo "alive pid=$(cat $PIDF)" || echo "dead" ;;
  *) echo "usage: $0 {status|apply <p0> <p4> <p7> <gpu> [oiface_1|0] [uclamp]|uclamp <n>|governor <n>|oiface {on|off}|reset|presets|setboot <0|1>|ensure|daemon|dstart|dstop|dstat}" ;;
esac
