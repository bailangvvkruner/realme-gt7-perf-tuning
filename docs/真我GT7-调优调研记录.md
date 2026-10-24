# 真我 GT7 (RMX5060) 性能/功耗调优完全调研记录

> 设备：realme RMX5060（真我 GT7）
> SoC：MT6989 / 天玑 9300
> 系统：Android 15（SDK 35）
> 内核：6.1.75-android14-11
> Root：KernelSU（ReSukiSU，包名 `com.resukisu.resukisu`）
> 记录时间：2026-10-24

---

## 目录

1. [连接与操作方式](#1-连接与操作方式)
2. [CPU 架构与调频](#2-cpu-架构与调频)
3. [oiface —— 厂商限频真凶](#3-oiface--厂商限频真凶)
4. [uclamp —— 有效的软限频手段](#4-uclamp--有效之前误判为失效已纠正)
5. [GPU 调频](#5-gpu-调频)
6. [内存与 ZRAM 深度分析](#6-内存与-zram-深度分析)
7. [swapfile 与 OPPO nandswap](#7-swapfile-与-oppo-nandswap)
8. [8.5GB zram1 的根治方案](#8-85gb-zram1-的根治方案)
9. [KernelSU WebUI 模块开发](#9-kernelsu-webui-模块开发)
10. [功耗治理结论](#10-功耗治理结论)
11. [未解决问题 / 内核限制](#11-未解决问题--内核限制)

---

## 1. 连接与操作方式

### adb 连接

```powershell
cd F:\Android\scrcpy
.\adb.exe connect 192.168.x.x:6666
```

`adb` 不在 PATH，必须用 `.\adb.exe`。

### 执行 root 命令的可靠姿势

PowerShell 引号嵌套极易出错，**不要用内联命令**，统一走：

```powershell
# 1. 本地写 .sh 文件
# 2. push
.\adb.exe push script.sh /data/local/tmp/script.sh
# 3. 赋权 + 执行
.\adb.exe shell "chmod 755 /data/local/tmp/script.sh; su -c 'sh /data/local/tmp/script.sh'"
```

### Root 身份确认

- `uid=0(root)`，SELinux 上下文 `u:r:ksu:s0`
- KernelSU 管理器：`com.resukisu.resukisu`（ReSukiSU）
- `ksud` 路径：`/data/adb/ksu/bin/ksud`

---

## 2. CPU 架构与调频

### 三集群规格

| policy | CPU 核心 | 架构 | 频率范围 | 可选档位数 |
|--------|----------|------|----------|-----------|
| `policy0` | cpu0–3 | Cortex-A520（能效核）| 300 MHz – 2.0 GHz | 18 |
| `policy4` | cpu4–6 | Cortex-A720（性能核）| 550 MHz – 2.85 GHz | 25 |
| `policy7` | cpu7 | Cortex-X4（超大核）| 600 MHz – 3.4 GHz | 29 |

注意：`policy7` 的 `cpuinfo_max_freq` 读到 3400000，但**实际写 3400000 回读只有 3250000**，硬件上限就是 3.25 GHz。

### 节点路径

```
/sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_max_freq
/sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_min_freq
/sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_governor
/sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_cur_freq
```

### 权限陷阱（重要）

cpufreq 节点默认权限是 `-r--r--r--`（**444，只读**）。

```bash
chmod 644 /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo 1500000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
```

- 444 时写入 → `Permission denied`
- chmod 644/666 后 → 写入成功（**可复现**）
- ⚠️ 权限会被系统自动恢复成 444，需要重复 chmod

### governor

- 默认：`sugov_ext`（联发科定制）
- 可选：`conservative`、`powersave`、`performance`、`schedutil`

---

## 3. oiface —— 厂商限频真凶

### 身份信息

```
pid     : 4490
comm    : B_p_0_c_7   （重启后会改名 horaeCb，但 exe 不变）
exe     : /system_ext/bin/oiface
ppid    : 1 (init second_stage)
```

### 它做了什么

持有以下节点的 fd，**持续抢占写入**：

- `policy0/4/7` 的 `scaling_cur_freq`
- `policy0/4/7` 的 `scaling_max_freq`
- `policy0/4/7` 的 `scaling_min_freq`
- `cpu*/online`
- `/sys/kernel/ged/hal/current_freqency`

### 对抗测试结果（2026-10-24 重测，结论已推翻）

**旧结论（作废）**：每 1 秒重写 `scaling_max_freq`，policy0/4 约 2 秒内被抢回满频。

**新实测**：在 oiface **保持运行**的情况下直接写 `scaling_max_freq`，
**15 秒内完全不被抢回**，重启 oiface 后也依然保持。

```
=== oiface 运行中硬写上限，观察 15 秒 ===
 1s  p0=1200000 p4=1000000 p7=1000000
 ...
15s  p0=1200000 p4=1000000 p7=1000000   ← 全程稳定
  oiface=running
```

**结论：不需要停 oiface 就能限频。** 旧结论大概是在 `persist.sys.oiface.enable=2`
且 oiface 正在处理新 hint 的窗口期测到的。

### oiface 平时自己就把频率压在 2300/2500

这是个容易误解的点 —— 默认状态下看到的 `scaling_max_freq` 并不是硬件上限：

| 集群 | 硬件上限 | oiface 默认压到 |
|------|---------|----------------|
| policy0 | 2000 MHz | 2000 MHz（不压）|
| policy4 | 2850 MHz | **2300 MHz** |
| policy7 | 3250 MHz | **2500 MHz** |

所以「原厂就已经在省电」，写满 2850/3250 反而是超频式放开。

### 开关方式

```bash
# 查看
getprop persist.sys.oiface.enable     # = 2 (启用)

# 停止（非必需，仅供彻底隔绝厂商调度）
stop oiface
setprop persist.sys.oiface.enable 0
```

---

## 4. uclamp —— ✅ 有效（之前误判为失效，已纠正）

> **重大更正（2026-10-24 夜）**：本章曾写「uclamp 已失效，写入被内核丢弃」，
> **这是错的**。真实原因是**违反内核的 `min ≤ max` 约束导致写入被 EINVAL 拒绝**，
> 与「失效」完全无关。详见下方「误判原因」。

### 内核支持情况

```
CONFIG_UCLAMP_TASK=y
CONFIG_UCLAMP_TASK_GROUP=y
CONFIG_UCLAMP_BUCKETS_COUNT=20
```

内核确实编入了 uclamp，且正在逐任务跟踪：

```
$ grep uclamp /proc/self/sched
uclamp.min                                   :                    0
uclamp.max                                   :                 1024
effective uclamp.min                         :                    0
effective uclamp.max                         :                 1024
```

### 误判原因（重要修正）

`sched_util_clamp_min` / `sched_util_clamp_max` / `sched_util_clamp_min_rt_default`
**三个节点共用一个内核 write handler**（`kernel/sched/core.c: sysctl_sched_uclamp_handler`）：

```c
if (write && sysctl_sched_uclamp_util_min > sysctl_sched_uclamp_util_max) {
        result = -EINVAL;
        goto done;
}
```

本机**出厂基线是 min=1024、max=1024**。只写 `clamp_max=512` 时，
状态变成 `min(1024) > max(512)` → **EINVAL，整个写入被拒绝，值保持 1024**。

之前的测试全部只改 max 不改 min，所以每次都撞在这个校验上，
被误读成「内核丢弃写入」。

**正确方法：先降 `clamp_min`，再降 `clamp_max`。**

```sh
echo 0   > /proc/sys/kernel/sched_util_clamp_min   # 必须先
echo 512 > /proc/sys/kernel/sched_util_clamp_max   # 立刻生效
```

回读验证：

```
写 min=0   → 0
写 max=512 → 512     （1 秒后仍 512）
写 max=256 → 256     （1 秒后仍 256）
```

辅助证据：
- 用 `sysctl -w` 写入会直接报错 `xwrite: Invalid argument`（即 EINVAL，不是静默重置）
- 单独写 `clamp_min` 一直正常生效
- 对照组 `vm.swappiness` 写 137 立即生效 137 → 写方法本身没问题
- 扫描 `/proc/*/fd` 确认无任何进程持有该节点 → 不是被别的服务抢写

### 功能验证：确实影响频率

2 线程负载下采样 `scaling_cur_freq`：

| `clamp_max` | A520 | A720 | X4 |
|-------------|------|------|-----|
| 1024 | 300 MHz | 2300 MHz | 2500 MHz |
| 512 | 1200 MHz | 2000 MHz | **600 MHz** |
| 256 | 1600 MHz | 1000 MHz | 900 MHz |
| 128 | 700 MHz | 550 MHz | 600 MHz |

注意 `clamp_max=512` 时 X4 直接掉到 600MHz（被 EAS 整体弃用），
说明 uclamp 不是「限上限」，而是**从调度器视角降低任务重量**，效果远比硬限频平滑，
而且会同时改变任务在三个集群间的摆放。

### 为什么 uclamp 比 `scaling_max_freq` 更好

- **保留突发余量**：短时高负载仍可冲高频，不会像硬限频那样把任务整体拖长
- **连续可调**（64–1024），不是离散频率档
- **同时影响任务摆放**：EAS 会把任务优先给能效核
- **不需要写 cpufreq 节点**（不用 chmod 644 绕过写保护）

但它也不是万能的：它压低的是调度器对任务「有多重」的判断，
**持续满载时硬限频仍然更精准**（见 9.6 数据对比）。

### 节点

```
/proc/sys/kernel/sched_util_clamp_max     # 0–1024，受 min ≤ max 约束
/proc/sys/kernel/sched_util_clamp_min     # 0–1024，出厂 1024
/proc/sys/kernel/sched_pelt_multiplier    # = 4，可写 1/2/4（无明显收益）
```

### 结论

**uclamp 是首选旋钮，`scaling_max_freq` 是补充手段。**
已集成进 `perf_ctl`（`UCLAMP_MAX` 配置项 + 守护防漂移），见第 9.5 章。

---

## 5. GPU 调频

### 限制

- devfreq governor = `dummy`，**由 GED 固件接管，无法直接锁频**
- 只能通过 boost / upbound 索引间接调节

### 可用节点

```
/sys/module/ged/parameters/gpu_cust_upbound_freq     # 默认 24
/sys/module/ged/parameters/gpu_cust_boost_freq       # 默认 260000
/sys/module/ged/parameters/gpu_bottom_freq           # 默认 130000
/sys/module/ged/parameters/gpu_idle                   # 默认 100
/sys/module/ged/parameters/is_GED_KPI_enabled        # 默认 1
/sys/module/ged/parameters/ged_smart_boost           # 默认 0
/sys/module/ged/parameters/ged_boost_enable
/sys/module/ged/parameters/dcs_mode
/sys/module/ged/parameters/fpsgo_enable
/sys/kernel/ged/hal/custom_boost_gpu_freq
/sys/kernel/ged/hal/custom_upbound_gpu_freq
```

### 频率索引表

`/sys/class/misc/mali0/device/devfreq/13000000.mali/available_frequencies`

共 **41 档**，1300 MHz → 260 MHz，13 MHz 步进：

| 索引 | 频率 | 索引 | 频率 |
|------|------|------|------|
| 1 | 1300 MHz | 24 | 702 MHz（默认 upbound）|
| 10 | 1183 MHz | 30 | 624 MHz |
| 20 | 858 MHz | 41 | 260 MHz |

### 实测结论

`gpu_cust_upbound_freq` **可写且不被覆盖**，实测 26 / 30 / 41 均生效。

```
26 → 约 663 MHz
30 → 约 624 MHz
41 → 260 MHz（最低）
```

---

## 6. 内存与 ZRAM 深度分析

### 内存实况

```
MemTotal      : 15700892 kB ≈ 15.0 GB
AnonPages     :  5796092 kB ≈  5.5 GB
Cached        :  4176820 kB ≈  4.0 GB
Slab          :  1441044 kB ≈  1.4 GB
MemAvailable  :  ~5.1 GB
```

### ZRAM 的真相（重要纠正）

`disksize = 9126805504` bytes = **8.5 GB 只是容量上限**。

- `mm_stat` 全 0
- 无 zsmalloc slab 分配
- **不预分配 1 字节物理内存**
- 未 swapon 时耗电为零

> ⚠️ 常见误解：以为 zram 的 disksize 会吃掉内存。**不会**。zram 只按实际写入量占用内存（压缩后）。

### disksize 能不能改

| 操作 | 结果 |
|------|------|
| 写 0 | ❌ REJECTED |
| 写 1 GB | ❌ REJECTED |
| 写 4 GB | ❌ REJECTED |
| `echo 1 > /sys/block/zram0/reset` | ✅ 清零成功 |

**规则：必须先 `reset` 才能改 `disksize`。**

### 完整重建 zram 的正确流程（踩坑记录）

```bash
# ❌ 错误：/sys/block/zram0 是符号链接指向目录
swapoff /sys/block/zram0     # failed: Is a directory
mkswap  /sys/block/zram0     # Is a directory
swapon  /sys/block/zram0     # Is a directory

# ✅ 正确：swap 操作必须用 /dev 路径
swapoff /dev/block/zram0
echo 1 > /sys/block/zram0/reset
echo zstd > /sys/block/zram0/comp_algorithm
echo 6442450944 > /sys/block/zram0/disksize   # 6144 MB
mkswap /dev/block/zram0
swapon /dev/block/zram0 -p 0
```

- `/sys/block/zram0` → 符号链接，**只能用于 sysfs 属性读写**
- `/dev/block/zram0` → 块设备节点，**用于 swapoff / mkswap / swapon**

### 压缩算法

```
可用：lzo  lzo-rle  lz4  [zstd]  lz4k
```

`zstd` 压缩率最高，但 CPU 开销也最大。16 GB 设备推荐 `zstd`。

### 压缩实况（12.5 GB 虚拟 swap 时）

| 设备 | 原始数据 | 压缩后实占 |
|------|----------|-----------|
| zram0 | 242 MB | **67 MB** |
| zram1 | 205 MB | **51 MB** |
| 合计 | 447 MB | **118 MB** |

压缩比约 3.8:1。

### 内存回收数据

```
pgsteal_file      : 370808526 页 ≈ 1414 GB
uptime            : 68 小时 28 分
平均回收速率      : 352 MB/分钟   ← 异常高
compact_stall     : 494
pgscan_kswapd     : 411108851
```

**352 MB/分钟的文件页回收意味着频繁的 UFS 重读 → 真实耗电。**

### vm 参数

```
/proc/sys/vm/swappiness            = 150  （Scene 设置，偏高）
/proc/sys/vm/watermark_scale_factor = 93   （偏高）
/proc/sys/vm/dirty_ratio            = 5
/proc/sys/vm/dirty_background_ratio = 2
/proc/sys/vm/vfs_cache_pressure     = 150
/proc/sys/vm/extra_free_kbytes      ← 不存在！
```

> ⚠️ Scene 日志声称把 `extra_free_kbytes` 设为 131072，但**该文件在此内核上不存在，写入静默失败**。

---

## 7. swapfile 与 OPPO nandswap

### 三种 swap 的区别

| 类型 | 存储介质 | 耗电 | 磨损 | 速度 |
|------|----------|------|------|------|
| **ZRAM** | 内存（压缩）| 低（只花 CPU）| 无 | 快 |
| **swapfile** | UFS 闪存 | **高**（真实读写）| **有** | 慢 |
| **zram1 (chp)** | 内存（压缩）| 低 | 无 | 快 |

### 曾出现的三个 swap

```
/dev/block/zram0   4194300 KB  Priority 0      ← Scene 配置 4GB
/dev/block/zram1   8912892 KB  Priority 7853   ← OPPO chp_swap 8.5GB
/data/swapfile     7864316 KB  Priority -2     ← Scene swapfile 7.5GB
```

> Priority 7853 是 chp zram1 的**魔法值**，必须等于 7853，否则内核不认。

### 开机 8.5 GB zram1 的元凶（dmesg 铁证）

`/product/etc/init/init.oplus.nandswap.rc:8`

```ini
on property:sys.boot_completed=1
    start nandswap
```

服务执行 `/product/bin/init.oplus.nandswap.sh`（**oneshot**，约 26s 时运行，0.6s 完成）：

```
zram0 capacity 0 -> 17825792 ; Adding 8912892k swap on zram0 Priority:32758 (normal_swap)
zram1 capacity 0 -> 17825792 ; Adding 8912892k swap on zram1 Priority:7853  (chp_swap)
```

随后 Scene 的 busybox（pid 1896，约 38s 时）把 zram0 重置为 8388608 扇区（4 GB），`swapon` 优先级 0，并触发 `swapd_stop` 让 hybridswapd 退出。

但 **zram1 的 8.5 GB 原样保留** → 这就是"开机那个 8G 死妈玩意"。

### swapfile 的来源

Scene 的 `scene_swap_controller` 模块：

- 脚本：`/data/adb/modules/scene_swap_controller/scripts/startup.sh`
- 其中 `readonly SWAP_FILE='/data/swapfile'`
- 配置：`/data/swap_config.conf`

```properties
swap=false
swap_size=7680
swap_priority=-2
swap_use_loop=false
zram=true
zram_size=4096
comp_algorithm=zstd
```

对应 `/data/swapfile` 7864316k、Priority -2，**完全吻合**。

当前 `swap=false` 且 `/data/swapfile` 已不存在。

> dmesg 提示：`F2FS-fs (dm-76): Swapfile (2) is not align to section`
> → f2fs 上的 swapfile 存在对齐问题，性能更差，**更不该用**。

### 文件系统

```
/data : /dev/block/dm-76  f2fs
        935 GB 总 / 827 GB 用 / 108 GB 余 (89% 已用)
```

内核配置：

```
CONFIG_SWAP=y
CONFIG_ZRAM=m
CONFIG_ZRAM_WRITEBACK=y
默认压缩算法：lzo-rle
```

---

## 8. 8.5GB zram1 的根治方案

### 方案对比

| 方案 | 做法 | 优点 | 缺点 |
|------|------|------|------|
| **A. 事后关闭** | 开机后 `swapoff` + `reset` zram1 | 简单 | 需等待 boot_completed，有窗口期 |
| **B. 源头屏蔽（推荐）** | 用 tmpfs 遮蔽 `/sys/kernel/mm/chp` | 彻底，zram1 根本不创建 | 无 |
| C. 保留现状 | 12.5 GB 虚拟 swap | 最省事 | 多一层无谓的 swap 层级 |

### 方案 B 原理（已验证有效）

OPPO 脚本的判定逻辑：

```bash
if [ -e "/sys/kernel/mm/chp/enabled" ]; then
    chp_supported=1
fi
...
if [ $chp_supported -eq 1 ]; then
    magic=7853
    mkswap /dev/block/zram1
    swapon /dev/block/zram1 -p $magic
fi
```

**用 tmpfs 覆盖整个 `chp` 目录**，`-e` 判定失败 → `chp_supported=0` → **zram1 根本不会被创建**。

```bash
mount -t tmpfs -o size=4k,mode=0755 tmpfs /sys/kernel/mm/chp
```

验证结果：

```
遮蔽前: /sys/kernel/mm/chp/enabled 存在
mount OK
遮蔽后: /sys/kernel/mm/chp/enabled 不存在 ✅
umount 后: 恢复存在 ✅
```

> `/sys/kernel/mm` 本身是 sysfs，但在其**子目录上覆盖 tmpfs 是允许的**（子挂载点独立）。
> 失败方案：`mount --bind /dev/null .../chp/enabled` → sysfs 不支持 bind 单个文件，`losetup failed`。

### 方案 A 的事后关闭（也验证可行）

```bash
swapoff /dev/block/zram1
echo 1 > /sys/block/zram1/reset
```

- 实测 OK，`SwapTotal` 从 12.5 GB 降到 4 GB
- 观察 15 秒**未自动恢复**（因为 `init.oplus.nandswap.sh` 是 oneshot 服务）

---

## 9. KernelSU WebUI 模块开发

### 规范

```
模块根目录/
├── module.prop
├── post-fs-data.sh      # 最早执行
├── service.sh           # 服务阶段
├── boot-completed.sh    # 开机完成
├── action.sh            # 管理器「操作」按钮
└── webroot/
    ├── index.html       # WebUI 入口
    ├── config.json      # WebUI 配置
    └── icon.png
```

### config.json

```json
{
  "title": "ZRAM 控制",
  "icon": "icon.png",
  "windowResize": false,
  "backInterceptor": "javascript",
  "contentSecurityPolicy": "default-src 'self' data: blob: {domain}; script-src * 'unsafe-inline' 'unsafe-eval' {domain}; style-src 'self' 'unsafe-inline' {domain}; connect-src *; img-src *;"
}
```

### JS API

```javascript
// 执行命令，回调签名 (errno, stdout, stderr)
globalThis.ksu.exec(cmd, JSON.stringify(opts), callbackName)
globalThis.ksu.toast(msg)

// 封装示例
function sh(cmd) {
  return new Promise((resolve, reject) => {
    if (typeof ksu === "undefined") { reject(new Error("请在 KernelSU 管理器中打开")); return; }
    const cb = "cb_" + Date.now() + "_" + Math.floor(Math.random() * 1e6);
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
    };
    ksu.exec(cmd, "{}", cb);
  });
}
```

### 参考实现

已安装的 WebUI 模块：`bindhosts`、`hybrid_mount`、`zygisksu`

```bash
cat /data/adb/modules/bindhosts/webroot/config.json
ls /data/adb/modules/bindhosts/webroot/
```

### 权限要求（踩坑）

```bash
chown -R root:root /data/adb/modules/模块名
chmod 755 /data/adb/modules/模块名
chmod 755 /data/adb/modules/模块名/*.sh
chmod 644 /data/adb/modules/模块名/module.prop
chmod 644 /data/adb/modules/模块名/webroot/*
```

> ⚠️ `adb push` 后所有者会是 `shell:shell`，**必须 chown root:root**，否则 KSU 读不到。

### 已建成的模块：`zram_ctl`

```
/data/adb/modules/zram_ctl/
├── module.prop          # id=zram_ctl, versionCode=100
├── post-fs-data.sh      # 尽早遮蔽 chp
├── service.sh           # 轮询探测 chp + 兜底关闭 zram1
├── action.sh            # 管理器「操作」按钮 → 打印 status
├── scripts/ctl.sh       # 统一控制入口
└── webroot/{index.html,config.json,icon.png}
```

配置文件：`/data/adb/zram_ctl.conf`
日志：`/data/adb/zram_ctl.log`

#### 开机执行时序

```
post-fs-data.sh   → 若 /sys/kernel/mm/chp/enabled 已存在，立即 tmpfs 遮蔽
service.sh        → 最多轮询 90 秒等待 chp 出现，一旦出现立刻遮蔽；
                    然后等 sys.boot_completed=1，再等 12 秒；
                    若 zram1 仍在运行，swapoff + reset 兜底
```

双保险设计：即使 post-fs-data 阶段 chp 还没注册，service 阶段也能补上；
即使遮蔽失败，boot_completed 后仍会事后关闭 zram1。

#### 验证结果

```
ksud module list → id=zram_ctl, web=true, action=true, enabled=true
ctl.sh status    → z0_size_mb=4096, z1_on=0, swap_total_mb=4096
apply 6144       → zram0 重建为 6144MB 成功，已用 1057.8MB，实占 300.5MB
apply 4096       → 恢复成功，swap 已清空
```

#### ctl.sh 命令

```bash
sh ctl.sh status                                  # 输出 key=value 状态
sh ctl.sh apply <swappiness> <watermark> <zram0_mb> <algo> <uclamp>
sh ctl.sh zram1off                                # 关闭 zram1
sh ctl.sh reset                                   # 清除配置
```

#### WebUI 可调项

| 项目 | 范围 | 说明 |
|------|------|------|
| zram0 容量 | 1024–12288 MB，512 步进 | 改动会重建 swap |
| swappiness | 0–200 | 默认 100 |
| watermark_scale_factor | 10–300 | 默认 50 |
| CPU uclamp_max | 64–1024 | ✅ **已证实有效**（需先降 `clamp_min`），zram_ctl 里旧实现已废弃，改用 `perf_ctl` |
| 压缩算法 | zstd/lz4/lzo-rle/lzo/lz4k | zstd 推荐 |

> **用户明确：屏幕刷新率/亮度不在调节范围内。**

---

## 9.5 `perf_ctl` —— 性能控制模块（zram_ctl 的升级版）

### 设计依据（全部来自实测）

| 事实 | 影响 |
|------|------|
| oiface 运行中写 `scaling_max_freq` **不会被抢回**（15s 验证） | **不需要停 oiface**，只做漂移守护 |
| `sched_util_clamp_max` **可用**（需先降 `clamp_min`） | 作为首选旋钮集成，`UCLAMP_MAX` 配置项 |
| oiface 默认把 p4/p7 压在 2300/2500 | “原厂”就是省电状态，滑块要能恢复这个值 |
| policy7 标称 3400 但内核只接受 3250 | `usable_max()` 硬编码封顶 |
| 写 max 前若 max < 当前 min 会 EINVAL | `set_cluster()` 先降 min 再写 max |

### 目录结构

```
/data/adb/modules/perf_ctl/
├── module.prop           # id=perf_ctl, web/action 均为 true
├── post-fs-data.sh       # 最早阶段 tmpfs 遮蔽 /sys/kernel/mm/chp
├── service.sh            # 延迟遮蔽重试 + zram1 兜底关闭 + 应用配置 + 起守护
├── action.sh             # 音量键动作 → ctl.sh status
├── scripts/ctl.sh        # 核心控制
└── webroot/
    ├── index.html        # 暗色 WebUI
    ├── config.json
    └── icon.png
```

### ctl.sh 命令表

```bash
sh ctl.sh status
sh ctl.sh apply <p0max> <p4max> <p7max> <gpu_idx> <oiface_off> [uclamp_max]
sh ctl.sh uclamp <64-1024>          # 单独调 uclamp
sh ctl.sh oiface {on|off}
sh ctl.sh governor <sugov_ext|conservative|powersave|performance|schedutil>
sh ctl.sh reset                     # 回出厂（含停守护）
sh ctl.sh presets                   # 预设表
sh ctl.sh setboot <0|1>             # 开机自启性能配置
sh ctl.sh ensure                    # 单次漂移修正
sh ctl.sh daemon | dstart | dstop | dstat
```

### uclamp 处理（关键）

```sh
# 内核强制 min <= max，否则 proc handler 返回 EINVAL 直接拒写
# （这就是旧结论“uclamp 失效”的真正原因）
set_uclamp() {
  want=$1
  cmin=$(cat /proc/sys/kernel/sched_util_clamp_min)
  if [ "$want" -lt "$cmin" ]; then
    echo 0 > /proc/sys/kernel/sched_util_clamp_min   # 必须先降下限
  fi
  echo "$want" > /proc/sys/kernel/sched_util_clamp_max
}
```

`reset` 恢复出厂时会 **先提 max 到 1024 再提 min 到 1024**，同样是为了绕开该校验。

### 守护防漂移（关键设计）

不抢频，只“守住”用户设定的值：

```sh
cmd_ensure() {
  load_conf; [ "$ACTIVE" = "1" ] || return 0
  for c in 0 4 7; do
    want=$(eval echo \$P${c}_MAX); um=$(usable_max $c)
    [ "$want" -gt "$um" ] && want=$um
    got=$(cat $(apath $c)/scaling_max_freq)
    [ "$got" != "$want" ] && { set_cluster $c "$want" "$(eval echo \$P${c}_MIN)"; }
  done
  # GPU 同理，uclamp 也守
}
```

- 仅当 `ACTIVE=1`（用户点过“应用”）才动作，否则纯空转
- 每 5 秒一次，实测守护进程 CPU 占用 **0.6%**
- 实测人为把 p7 max 写成 800000，**1 秒内被改回 2000000**

#### 交叉约束处理（踩坑）

```sh
# 若要写的新 max 低于当前 min，内核会直接 EINVAL 拒绝
# 所以: 先检查 -> 先降 min -> 再写 max -> 最后写目标 min
if [ "$nmax" -lt "$cmin" ]; then echo "$nmin" > "$fmin"; fi
echo "$nmax" > "$fmax"
echo "$nmin" > "$fmin"
```

### 预设档位（基于实测能效，非拍脑袋）

| 预设 | p0(A520) | p4(A720) | p7(X4) | GPU idx | uclamp_max |
|------|----------|----------|--------|---------|------------|
| 省电 | 1200 | 1400 | 1400 | 38 (338MHz) | 256 |
| 均衡 | 2000 | 2300 | 2500 | 24 (702MHz) | **512** |
| 原厂 | 2000 | 2300 | 2500 | 24 (702MHz) | 1024 |
| 性能 | 2000 | 2600 | 2900 | 20 (806MHz) | 1024 |

设计约束：**每档内部必须保持 p0 ≤ p4 ≤ p7 的性能梯度，不得倒挂**。
倒挂会导致 EAS 把任务分给能效更差的 A520，执行时间变长，总能耗反而上升。

**均衡档不硬限频，只靠 `uclamp 512`**：实测 8 线程吞吐与原厂持平（2.40 vs 2.42 M/s），
能耗却从 109 J 降到 82 J（**−25%**），单线程 54 J → 42 J（**−22%**）。
这是唯一一档“白捧”的配置——不牺牲速度就能省电，因为它只消除了调度器的过度乐观。

性能档故意**不用硬件满频**：实测满频 16.2 W / 87℃，能耗 +35%，吞吐只 +8%。

---

## 9.6 能效实测（本机真测数据）

### 测量方法

```
固定工作量: 8 线程 × 5,000,000 次 shell 算术迭代
计时:       /proc/uptime（`date +%s%N` 在 mksh 下不可靠，会出负数）
功率:       battery/current_now × voltage_now，负载稳态窗口内 12 次采样取均
能耗:       E = P × T
```

> `charge_counter` 分辨率只有 1 mAh，10 秒内变化量为 0，不能用于短时测量。
> `current_now` 单点噪声很大（155→775 mA，受后台应用影响），必须窗口内多次取均。

### 8 线程满载

| 配置 | 电流 | 功耗 | 耗时 | **总能耗** | 吞吐 | 温升 |
|------|------|------|------|-----------|------|------|
| 满频 2000/2850/3250 | 4184 mA | 16.21 W | 13.9 s | 225.1 J | 2.88 M/s | 40→**87℃** |
| 原厂 2000/2300/2500 | 2840 mA | 11.16 W | 15.0 s | 167.1 J | 2.67 M/s | 36→69℃ |
| 中限 1600/1800/1800 | 1621 mA | 6.43 W | 18.9 s | **121.9 J** | 2.11 M/s | 42→60℃ |
| 低限 1200/1400/1400 | 1037 mA | 4.15 W | 25.0 s | **103.6 J** | 1.60 M/s | 41→49℃ |
| 关X4 + 满频 | 3409 mA | 13.31 W | 18.0 s | 240.1 J | 2.22 M/s | 42→63℃ |
| 关X4 + 中限 | 1436 mA | 5.72 W | 22.9 s | 130.8 J | 1.75 M/s | 43→51℃ |

### 单线程 / 双线程

| 配置 | 1线程 功耗/耗时/**能耗** | 2线程 功耗/耗时/**能耗** |
|------|------------------------|------------------------|
| 原厂 | 2.88 W / 17.2 s / 49.6 J | 4.26 W / 9.3 s / 39.5 J |
| 中限 | 1.65 W / 23.7 s / **39.1 J** | 2.42 W / 11.9 s / 28.8 J |
| 低限 | 1.45 W / 31.1 s / 45.2 J | 1.62 W / 15.3 s / **24.8 J** |

### 待机（无负载）

| 配置 | 平均电流 |
|------|----------|
| 原厂 2000/2300/2500 | 165 mA |
| 低限 1200/1400/1400 | 159 mA |

差 **3.6%**，基本无差别。待机时 CPU 本就跑在最低频，改 `max_freq` 没有意义。

### 四个反直觉结论

**1. 功耗随频率超线性增长**

满频 16.2 W vs 中限 6.4 W（2.5 倍），但吞吐只从 2.11 到 2.88（1.37 倍）。
因为功耗 ∝ f·V²，而 V 随 f 上升，高频段的边际功耗成本极高。

**2. 单线程下「省电档」不如「均衡档」**（45.2 J vs 39.1 J）

典型的 race-to-idle 拐点：压得狠导致运行时间从 23.7 s 涨到 31.1 s，
功耗降的那点被时间拉长全吃掉了。**1500–1800 MHz 附近是单线程的能效甜点。**
（但低限 45.2 J 仍优于原厂 49.6 J，只是不如中限。）

**3. 关掉 X4 大核是负优化**（240.1 J > 225.1 J）

少一个核 → 8 线程抢 7 核 → 时间从 13.9 s 涨到 18.0 s，
A720 被迫跑更高频承担更多活，省下的功耗不够抵消时间成本。
只有轻载/待机时关 X4 才可能有效，重载下别用。

**4. 原厂 2300/2500 已经接近最优**

比满频省 26% 能耗，吞吐只掉 7%。厂商确实调过。
「性能档」写满 3250 是纯粹的浪费，还会冲到 87℃ 触发热控。

### 推论：调频治不了待机耗电

待机三档电流差 3.6%。用户抱怨的耗电，**必须从后台应用下手**
（当时 loadavg 15–17，`com.tencent.mobileqq` 常年占 60%+）。
调 `max_freq` 只对「正在跑重负载」的时段有意义。

---

### uclamp 能效实测（v1.1 新增，统一口径）

测量条件与 9.6 一致：`/proc/uptime` 计时，稳压窗口内 `current_now × voltage_now` 取均，
`E = P × T`。8 线程 × 3,000,000 次迭代 / 1 线程 × 8,000,000 次迭代（总工作量固定）。

**8 线程**

| 配置 | uclamp | 功耗 | 耗时 | 能耗 | 吞吐 |
|------|--------|------|------|------|------|
| 性能 2000/2600/2900 | 1024 | 13.58 W | 9.9 s | 134.7 J | 2.42 M/s |
| 原厂 2000/2300/2500 | 1024 | 10.97 W | 9.9 s | 108.7 J | 2.42 M/s |
| **原厂 + uclamp 512** | 512 | 8.21 W | 10.0 s | **82.2 J** | 2.40 M/s |
| 原厂 + uclamp 384 | 384 | 6.16 W | 12.3 s | 75.7 J | 1.95 M/s |
| 原厂 + uclamp 256 | 256 | 3.34 W | 19.2 s | 64.3 J | 1.25 M/s |
| 省电 1200/1400/1400 + uc256 | 256 | 3.03 W | 20.2 s | 61.3 J | 1.19 M/s |

**1 线程**

| 配置 | uclamp | 功耗 | 耗时 | 能耗 | 吞吐 |
|------|--------|------|------|------|------|
| 性能 2000/2600/2900 | 1024 | 3.86 W | 14.8 s | 57.1 J | 0.54 M/s |
| 原厂 | 1024 | 3.20 W | 16.9 s | 54.2 J | 0.47 M/s |
| **原厂 + uclamp 512** | 512 | 1.93 W | 21.8 s | **42.1 J** | 0.37 M/s |
| 原厂 + uclamp 384 | 384 | 1.48 W | 31.9 s | 47.3 J | 0.25 M/s |
| 原厂 + uclamp 256 | 256 | 1.09 W | 44.4 s | 48.1 J | 0.18 M/s |

### uclamp 的三个结论

**1. `uclamp 512` 是「白捡」的省电——不牺牲速度**

8 线程吞吐 2.40 vs 原厂 2.42 M/s（**−0.8%，在误差内**），能耗 82.2 vs 108.7 J（**−24%**）；
单线程耗时 21.8 vs 16.9 s（−29% 速度），能耗 42.1 vs 54.2 J（**−22%**）。

原因：原厂 `uclamp=1024` 让调度器以为每个任务都是满负荷，于是把 X4 拉到 2500、
A720 拉到 2300；但这个工作量实际受内存/解释器瓶颈限制，**降频后吞吐几乎不变**。
uclamp 只是消除了这种「过度乐观」，属于纯赚。

> 注意口径：本测试负载（shell 解释器循环）**不完全受 CPU 频率限制**，
> 所以「降频不掉吞吐」这个结论不能无脑推广到纯向量计算。
> 但它恰好代表了日常场景（UI、网络、脚本、编译碎片）的典型特征。

**2. 持续满载时硬限频更精准**

8 线程下 `uclamp 384`（75.7 J）不如 `max_freq 1600/1800/1800`（74.7 J）；
两者叠加（`uclamp384 + maxfreq1600`）也只有 75.5 J，**没有协同收益，取其一即可**。

所以分工是：
- **轻/中载、日常使用 → 用 uclamp**（保留突发余量，不卡顿）
- **持续重载、长时间游戏 → 用 max_freq**（限制更硬更省）

**3. uclamp 调太低也会反噬**

单线程下 `uc256`（48.1 J）反而比 `uc512`（42.1 J）费电——和 9.6 里
「低限频不如中限频」是同一个 race-to-idle 效应：
把任务拖长到 44 秒，待机底噪的积分反而吃掉了降频省下的部分。

### uclamp vs max_freq 的能力对比

| | uclamp | max_freq |
|---|---|---|
| 粒度 | 连续 64–1024 | 离散频率档 |
| 突发余量 | **保留** | 被硬切 |
| 是否影响任务摆放 | **会**（EAS 会把任务赶去能效核） | 不会 |
| 持续满载精准度 | 一般 | **更好** |
| 写入难度 | 需先降 `clamp_min`（内核 min ≤ max 校验） | 需 `chmod 644` 绕过写保护 |
| 会被厂商服务改动 | 实测不会 | 实测不会 |

两者互补，所以 `perf_ctl` 两个都做了。

---

### oiface 要不要停？（结论：不要）

实测三组场景，全程保持 `oiface` 运行（`persist.sys.oiface.enable=2`）：

| 场景 | 时长 | `max_freq` | `uclamp_max` | GPU idx |
|------|------|-----------|--------------|---------|
| 8 线程满载 | 20 s | 2000/2300/2500 不变 | 512 不变 | 24 不变 |
| 息屏 Dozing ↔ 亮屏 Awake | 35 s（17 次采样） | 不变 | 不变 | 不变 |
| 打开/切换设置 App | 10 s | 不变 | 不变 | 不变 |

**关键点：这些测试期间守护进程是关闭的**，所以「值没变」完全是 oiface 没碰，
不是被守护改回来。

因此：
- **不需要在人工调整时自动停 oiface**
- 停 oiface 反而丢掉厂商的触控/游戏 boost，得不偿失
- WebUI 里的「停止 oiface」只留作兜底（万一某些机型/版本行为不同）

---

### 踩坑：守护进程重复启动（v1.1 修复）

现象：连续调用 `apply` 后 `reset` 明明写了 `uclamp=1024/1024`，
3 秒后又被改回 `512`，配置文件也「复活」了。

根因：旧实现是

```sh
( sh "$0" daemon >/dev/null 2>&1 & )   # 子 shell 里启动，父 shell 拿不到 $!
```

`daemon_alive()` 只能看到「PIDF 里记录的那一个」。两次 `apply` 挨得近时，
第二个守护在第一个写入 PIDF **之前** 也通过了存活检查 → **起了两个守护**。
第二个把 PIDF 覆盖成自己的 pid，第一个变成孤儿，继续按它 `load_conf` 到的旧配置回写。
于是 `reset` 刚写完就被孤儿守护改回去，看起来像「reset 失效」。

修复：

```sh
dae_kill_all() {   # 按 cmdline 杀干净所有游离守护
  for p in $(ps -A -o PID,ARGS | grep 'ctl\.sh daemon' | grep -v grep | awk '{print $1}'); do
    [ "$p" != "$$" ] && kill -9 "$p"
  done
  rm -f "$PIDF"
}
cmd_daemon_start() {
  daemon_alive && return 0
  dae_kill_all
  sh "$0" daemon >/dev/null 2>&1 &
  echo $! > "$PIDF"          # 父 shell 直接记 PID，不再有竞争
}
cmd_daemon() {               # 守护自身也做双实例互斥
  [ -f "$PIDF" ] && { o=$(cat "$PIDF"); [ "$o" != "$$" ] && [ -d "/proc/$o" ] && exit 0; }
  echo $$ > "$PIDF"
  ...
}
```

验证：连续 `apply` 三次后守护数恒为 **1**；`reset` 后 6 秒仍是 `1024/1024`，配置已删。

### 踩坑：oiface「停止不了」（v1.1.1 修复）

用户反馈：**「怎么调 oiface 都是运行中，停止不了，应用配置也不行」**。

先排除外部原因（都实测过）：

| 怀疑点 | 实测结果 |
|---|---|
| `stop oiface` 命令本身无效 | ❌ 不是。`init.svc.oiface` 确实变 `stopped`，进程 25027 消失 |
| 停了会被 init 自动拉起 | ❌ 不是。连续监控 **200 秒** 一直是 `stopped` |
| `persist.sys.oiface.enable=2` 导致无法停 | ❌ 不是。该 prop 不影响 `stop` |
| 嵌套 `su -c` 失败 | ❌ 不是。已在 root 下再跑 `su -c id`，仍为 uid=0 |
| oiface 重启后会改回自己的频率 | ❌ 不是。启动后 25 秒，`1400000/1400000` 纹丝不动 |

**真因在模块自己的逻辑**，两处：

1. `cmd_apply` 里写的是 `if [ "$OIFACE_OFF" = "1" ]; then oiface_stop; else oiface_start; fi`
   —— `else oiface_start` 导致**每次点「应用配置」都把 oiface 拉回来**。
2. `oiface on/off` 子命令**从未 `save_conf`**，所以 `OIFACE_OFF` 永远是 0，
   WebUI 下次 apply 又传 0 → 又 `oiface_start`。

于是用户体验就是：点「停止」→ 已停止 → 点「应用配置」→ 又运行中，永远停不掉。

修复（三处）：

```sh
# 1) 只停不起：0 仅表示“不去碰它”，绝不主动 start
[ "$OIFACE_OFF" = "1" ] && oiface_stop

# 2) 第 5 参语义改为：1 = 停止；0/空 = 保持配置里的值（不能用 0 覆盖 1）
if [ "$5" = "1" ]; then OIFACE_OFF=1; fi

# 3) on/off 必须持久化
off) load_conf; OIFACE_OFF=1; save_conf; oiface_stop; echo "OK state=$(oiface_state)" ;;
on)  load_conf; OIFACE_OFF=0; save_conf; oiface_start; echo "OK state=$(oiface_state)" ;;
```

WebUI 侧：

- 预设数组从 6 元组改回 5 元组（去掉 oiface 字段），一键预设不会再把 oiface 拉起来
- `apply` 的 oiface 参数永远取 `D.cfg_oiface_off`
- 状态卡新增「配置（是否要求停止）」行，区分「实际状态」与「期望状态」
- `sh()` 改为**自动探测执行身份**：先跑 `id`，是 root 就直接执行，不是才套 `su -c`
  （WebUI 本身常常已是 root，多套一层 `su` 可能失败或卡住）

验证：

| 操作 | conf OIFACE_OFF | oiface 实际 |
|---|---|---|
| `oiface off` | 1 | stopped |
| 接着 `apply ... 0 ...` | **1（不被覆盖）** | stopped |
| `oiface on` | 0 | running |
| `reset` | 删 conf | running（出厂） |

> **副产结论**：`stop oiface` 在这台机器上完全有效且不会被拉起，
> 所以「想停就能停」——只是实测没必要停（见上一节）。

---
### WebUI 界面

- **实时状态**：三集群当前频率 + GPU + oiface + 限频生效（含漂移提示）+ 三区温度 + 前台应用 + 负载/电量
- **预设**：省电 / 均衡 / 性能 / 原厂（一键写入并应用）
- **实测依据卡**：直接展示 9.6 的能耗对比表，说明每个预设为什么这么定
- **CPU 上限**：三个滑块（X4 / A720 / A520）+ GPU 索引滑块，显示 MHz 并按硬件上限自适应
- **uclamp_max 滑块**：64–1024，带分级提示（轻度/中度/强限制），状态栏显示「全局值 + 任务实际值」
- **oiface**：停止 / 恢复（**实测无需停，默认保持运行**，仅彻底隔绝厂商调度时才停）
- **生效**：应用配置 / 刷新 / 恢复出厂 / 开机自启开关
- 4 秒自动刷新；拖动滑块时暂停同步避免跳动

### 验证结果

```
apply 1800000 2000000 2000000 30 0   → OK (err=0)
dstat  （su 退出 2 秒后）              → alive pid=22703
drift 测试                            → 1 秒内被守护修正
daemon CPU 占用                        → 0.6%
ksud module list                       → id=perf_ctl web=true action=true enabled=true

// v1.1 补充验证（能效实测后）
reset                                 → p0=2000000 p4=2300000 p7=2500000 gpu=24（稳住不漂）
apply 1600000 1800000 1800000 30 0    → 8 秒无漂移
gpu 漂移修正                          → 写 5，7 秒后被守护改回 30

// v1.1.0（uclamp 集成 + 守护去重）
uclamp 384  / uclamp 1024              → 均 OK，uclamp_max 与 uclamp_eff_max 一致
apply ... 512                         → uclamp_eff_max=512（全局值真的下发了）
人为写 uclamp=900，3 次                  → 每次 6 秒内被守护改回 512
连续 apply 3 次                        → 守护数恒为 1（旧版会是 2～3）
reset                                 → 1024/1024，6 秒后不变，conf 已删，守护已死
8 线程满载 20 秒                        → 2000/2300/2500 + uc512 + gpu24 全部不变
息屏 Dozing ↔ 亮屏 Awake（17 次采样）      → 同上，全部不变（守护当时是关的）
```

### reset 的语义

`reset` 写入的是 **oiface 自己的目标值 2000/2300/2500**，不是硬件满频
（旧版本写 `usable_max()` 是错的：实测满频纯浪费，功耗 +50%）。

### 守护的生命周期

- `apply` 后自动启动，5 秒一轮
- 模块目录出现 `disable` 或被卸载 → 守护自尽，不留幽灵进程
- `reset` / `dstop` 手动停

### 与 zram_ctl 的关系

`perf_ctl` 是 `zram_ctl` 的超集（同样包含 chp 遮蔽 + zram1 兜底关闭）。
两者同时启用不会冲突（第二个检测到已是挂载点会跳过），
确认 `perf_ctl` 重启后遮蔽正常即可禁用 `zram_ctl`。

---

## 10. 功耗治理结论

### 优先级排序（对症下药）

#### 第 1 优先：处理后台高 CPU 应用

实测 loadavg ≈ **15.36**，而设备只有 8 核（满载 = 8.0）。**这已经是核数两倍**，说明存在严重的 CPU 排队。

无我方残留进程，来源全在应用：

| 进程 | CPU 占用 |
|------|----------|
| `com.tencent.mobileqq` | **66.6%** |
| `com.hbsclj.uth` | 10.7% |
| `system_server` | 9.6% |
| `surfaceflinger` | 8.8% |
| `systemui` | 8.8% |

**→ 先把 QQ 和 `com.hbsclj.uth` 的后台活动掐掉，收益远大于任何内核调参。**

#### 第 2 优先：直接限频（`scaling_max_freq`）

第 1 项做完后再考虑。写 `scaling_max_freq` 不会被 oiface 抢回。

**但先搞清楚它到底能省多少（已经实测过，见 9.6）：**

| 场景 | 低限(1200/1400/1400) vs 原厂 | 中限(1600/1800/1800) vs 原厂 |
|------|------------------------------|------------------------------|
| 待机 | -3.6% | 基本无差别 |
| 1 线程 | -9% | **-21%** |
| 2 线程 | **-37%** | -27% |
| 8 线程 | **-38%** | -27% |

所以：**限频只在后台真在跑负载时才省电，且没有单一档位全场景最优。**
日常用选「**均衡**」——它不是硬限频，而是**原厂频率 + `uclamp 512`**，
实测 8 线程吞吐与原厂持平、能耗 -24%（见 9.6），单线程能耗 -22%。
需要长时游戏/压测时再手动切「省电」。

> uclamp **有效**（见第 4 章，之前“已失效”的结论是错的），且优于硬限频。
> 关 X4 大核已实测为负优化（见 9.6），不要用。

#### 第 3 优先：ZRAM 策略

- 保留 4–6 GB ZRAM，**不要关闭**
- 理由：`AnonPages = 5.5 GB`，无 swap 会导致 1414 GB 文件页被回收，UFS 重读更耗电
- `swappiness` 从 150 降到 100 左右

#### 第 4 优先（不推荐）：停 oiface 硬限频

代价：失去厂商调度优化、可能影响性能调度、需要看门狗（1 秒轮询都不够）。

### Scene「省电模式」的真实效果

Scene 的省电模式（`powercfg.xml` 中 `com.hbsclj.uth → powersave`）本质是切换 governor / 限制 max_freq。

**注：旧结论「oiface 会在 2 秒内抢回满频」已被推翻**。重测确认 oiface 运行中写入
`scaling_max_freq` 15 秒全程不被抢回（见第 3 章）。
所以 Scene 的省电模式是能生效的——但正如 9.6 实测，**限频本身对省电的收益就有限**，
所以它「看起来没用」的真正原因是手段选错了，而不是被厂商抢回。

Scene 的 `files/powercfg.sh` 是**解除厂商限制**脚本：

```bash
echo "300000 2000000 550000 2850000 600000 3250000" > ...perfserv_freq
# 并 bind mount 覆盖 adpf_enable，现读为 0
```

这说明 Scene 自己也知道厂商限频的存在，但它选择的是**解除限制**而非施加限制。

---

## 11. 未解决问题 / 内核限制

| 项目 | 状态 | 原因 |
|------|------|------|
| sched_ext / scx BPF 调度器 | ❌ 不可用 | 内核缺 `CONFIG_SCHED_CLASS_EXT`，`/sys/kernel/sched_ext` 不存在 |
| GPU 直接锁频 | ❌ 不可行 | devfreq governor = `dummy`，由 GED 固件接管 |
| 热控 `min_throttle_freq` | ❌ 只读 | 内核层只读，chmod 也无效 |
| 直接写 `scaling_max_freq` | ✅ 可用 | 已推翻旧结论：oiface 不抢回（见第 3 章） |
| `extra_free_kbytes` | ❌ 不存在 | 此内核无该节点，Scene 的写入静默失败 |
| `hybridswap_enable` 写入语义 | ❓ 未验证 | 读回是状态字符串 `"hybridswap disable reclaim_in disable swapd disable"`，非 0/1 |
| `persist.sys.oplus.nandswap=false` | ⚠️ 无效 | 设为 false 后 zram1 仍被创建，说明判定不只看这个 prop |

### 已确认可写的节点清单

文件层可写（`[WRITABLE]`），但**能写 ≠ 生效**，已标注实际效果：

```
sched_util_clamp_max / sched_util_clamp_min   ✅ **有效**（先降 min 再写 max，否则 EINVAL），已集成 perf_ctl
sched_pelt_multiplier                          ⚠️ 可写 1/2/4，无明显收益
gpu_cust_upbound_freq / gpu_bottom_freq        ⚠️ 能写，但会被 GED 自行改动（实测 24→38），需守护
is_GED_KPI_enabled / ged_smart_boost / ged_boost_enable   ✅
dcs_mode / fpsgo_enable                        ✅
fbt/enable_ceiling                             ✅
mtk-dvfsrc-devfreq/min_freq                    ✅
cpu4/core_ctl/enable                           ✅（但 min=max=3，热插拔未启用）
cpu7/online                                    ✅ 可 offline 大核（实测有效，但重载下是负优化）
swappiness / watermark_scale_factor            ✅
scaling_max_freq / scaling_min_freq            ✅ 真实生效，oiface 不抢回（chmod 644 后）
```

---

## 附录：关键路径速查

### CPU

```
/sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_{min,max}_freq
/sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_governor
/proc/sys/kernel/sched_util_clamp_max
/proc/sys/kernel/sched_util_clamp_min
```

### GPU

```
/sys/module/ged/parameters/gpu_cust_upbound_freq
/sys/module/ged/parameters/gpu_bottom_freq
/sys/class/misc/mali0/device/devfreq/13000000.mali/available_frequencies
```

### 内存

```
/sys/block/zram{0,1}/{disksize,reset,comp_algorithm,mm_stat}
/dev/block/zram{0,1}
/proc/swaps
/proc/meminfo
/proc/sys/vm/{swappiness,watermark_scale_factor,dirty_ratio,vfs_cache_pressure}
```

### OPPO nandswap

```
/product/etc/init/init.oplus.nandswap.rc
/product/bin/init.oplus.nandswap.sh
/sys/kernel/mm/chp/{enabled,bug_on,anon_enable,alloc_oom,uid_blacklist}
/sys/block/zram0/hybridswap_{enable,core_enable,swapd_pause,loop_device,loglevel}
```

### Scene

```
/data/data/com.omarea.vtools/shared_prefs/powercfg.xml
/data/data/com.omarea.vtools/files/powercfg.sh
/data/swap_config.conf
/data/adb/modules/scene_swap_controller/
/cache/lmkd_opt.log
/cache/cgroup_opt.log
```

### KernelSU

```
/data/adb/ksu/bin/ksud
/data/adb/modules/<模块名>/
/data/adb/zram_ctl.conf
/data/adb/zram_ctl.log
/data/adb/perf_ctl.conf
/data/adb/perf_ctl.log
/data/adb/perf_ctl.pid
```

---

## 变更记录

| 时间 | 内容 |
|------|------|
| 2026-10-24 | 完成 oiface 定位、uclamp 实测、GPU 索引表、zram 真相、nandswap 元凶溯源 |
| 2026-10-24 | 发现 tmpfs 遮蔽 `/sys/kernel/mm/chp` 可从源头阻止 zram1 创建 |
| 2026-10-24 | 建成 `zram_ctl` KernelSU WebUI 模块并测试通过 |
| 2026-10-24 | 修正 swap 操作路径：必须用 `/dev/block/zramN` 而非 `/sys/block/zramN` |
| 2026-10-24 | **推翻旧结论**：oiface 运行中写 `scaling_max_freq` 不会被抢回（15s 验证）|
| 2026-10-24 | 建成 `perf_ctl` 模块：三集群限频 + GPU 档位 + 守护防漂移 + WebUI |
| 2026-10-24 | 测试事故：`kill %1` 在 Android `sh` 无效导致 8 个死循环进程占满 CPU；
`timeout -s KILL` 包裹的子进程会被 reparent，`$!` 拿错 PID。已全部清理 |
| 2026-10-24 | **完成能效实测（见 9.6）**，推翻自己拍定的预设档位 |
| 2026-10-24 | **修正预设**：省电改为 1200/1400/1400（原 1200/1000/1000 是频率倒挂错误）；
均衡改为 1600/1800/1800；性能不再用满频 3250，改为 2600/2900 |
| 2026-10-24 | ~~以上均衡 1600/1800/1800~~ **已被当晚的 uclamp 实测取代**：均衡改为「原厂频率 + uclamp512」（见下方条目）|
| 2026-10-24 | **新发现**：单线程下低限（45.2J）反而比中限（39.1J）更耗电，race-to-idle 拐点在 1500–1800 MHz |
| 2026-10-24 | **新发现**：关掉 X4 大核是负优化（240.1J > 225.1J），不得用作省电手段 |
| 2026-10-24 | **新发现**：待机电流三档只差 3.6%，限频治不了待机耗电，必须治后台 |
| 2026-10-24 | **方法论**：`date +%s%N` 在 mksh 下返回负数不可用；改用 `/proc/uptime`；
`charge_counter` 分辨率 1mAh 太粗；负载用自终止循环 + `wait`（不用 timeout） |
| 2026-10-24 夜 | **重大更正（推翻自己的错误结论）**：`sched_util_clamp_max` **没有失效**！
之前「写入恒被重置为 1024」的根因是内核强制 `min ≤ max`，出厂 `min=1024` 时只降 max 会 EINVAL 被拒。
正确写法：**先写 `clamp_min=0`，再写 `clamp_max`**。已修正第 4 章 |
| 2026-10-24 夜 | **uclamp 能效实测**：`uclamp 512` 在 8 线程吞吐不变（2.40 vs 2.42 M/s）的前提下省 **24%** 能耗；
单线程省 22%。已写入 9.6 |
| 2026-10-24 夜 | **`perf_ctl` v1.1**：新增 `UCLAMP_MAX` 配置与 WebUI 滑块，守护同时防 uclamp 漂移 |
| 2026-10-24 夜 | **重新定档**：均衡改为「原厂频率 + uclamp 512」（不再硬限频，保留突发余量） |
| 2026-10-24 夜 | **验证 oiface 无需停止**：满载 20s / 息屏↔亮屏 35s / 切 App 全程，
`max_freq`、`uclamp`、GPU 全部不变，**且当时守护是关着的**，排除「守护改回」干扰 |
| 2026-10-24 夜 | **修复守护重复启动 bug**：旧实现 `( sh "$0" daemon & )` 拿不到 `$!`，
连续 `apply` 会起多个守护互相覆盖配置，导致 `reset` 被孤儿守护改回。
改用父 shell 记账 `$!` + 按 cmdline 清场 + 守护自互斥 |
| 2026-10-24 深夜 | **修复「oiface 停止不了」bug**（用户反馈）：真因是 `apply` 里的 `else oiface_start`
每次应用配置都把 oiface 拉回来，且 `oiface on/off` 从未 `save_conf`。
改为「只停不起」+ `off/on` 持久化 + 第5参 1=停/0=不动。v1.1.1 |
| 2026-10-24 深夜 | 验证 `stop oiface` 确实生效：**监控 200 秒无自动拉起**，`oiface` 重启也不会改回频率 |
