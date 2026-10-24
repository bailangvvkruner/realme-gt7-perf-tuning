# 真我 GT7（RMX5060 / 天玑9300）调优记录 + perf_ctl 模块

一次从「为什么这机器耗电」查到「到底哪个旋钮真的有用」的完整实测记录，
外加一个把结论落地的 KernelSU 模块。

- **设备**：realme RMX5060（真我 GT7），MT6989 / 天玑 9300
- **系统**：Android 15（SDK 35），ColorOS 15
- **内核**：6.1.75-android14-11
- **Root**：KernelSU（ReSukiSU）

---

## 一句话结论

| 旋钮 | 是否有效 | 说明 |
|---|---|---|
| `scaling_max_freq`（硬限频） | ✅ 有效 | 写入后 **oiface 不会抢回**（旧结论错误） |
| `sched_util_clamp_max`（uclamp） | ✅ 有效 | 需**先降 `clamp_min`**，否则 `min>max` 被 EINVAL 整条拒绝 |
| GPU `gpu_cust_upbound_freq` | ⚠️ 可写 | 会被 GED 自行改动，**必须靠守护盯** |
| 关 X4 大核 / offline | ❌ 负优化 | 满载能耗反而 +6% |
| 关 ZRAM | ❌ 不建议 | `AnonPages ≈ 5.6 GB`，无 swap 会更耗电 |
| 屏幕亮度/刷新率 | — | 不在本项目范围内 |

**最优解不是把频率压到最低。** 实测 `uclamp 512` 在 8 线程负载下：

- 吞吐 2.40 M/s vs 原厂 2.42 M/s（**几乎持平**）
- 能耗 82.2 J vs 原厂 108.7 J（**−24%**）

原因：这类负载受缓存/延迟限制，降频不掉吞吐，只是消除了调度器「以为满载 → 把 X4 拉到 2500MHz」的过度乐观。

---

## perf_ctl 模块

KernelSU 模块，带 WebUI，手动调节 CPU 三集群限频 / uclamp / GPU 档位。

### 安装

```bash
# 把 perf_ctl/ 目录打包成 zip 后通过 KernelSU 管理器安装
cd perf_ctl && zip -r ../perf_ctl.zip . -x '.*'
```

或直接把 `perf_ctl/` 整个目录放到 `/data/adb/modules/perf_ctl/`，重启。

### 打开 WebUI

**ReSukiSU 管理器 → 模块 → 性能控制 → 打开**

### 预设档位

| 档位 | p0 (A520) | p4 (A720) | p7 (X4) | GPU | uclamp_max |
|---|---|---|---|---|---|
| 省电 | 1200 MHz | 1400 MHz | 1400 MHz | idx 38 (338MHz) | 256 |
| **均衡** | 2000 MHz | 2300 MHz | 2500 MHz | idx 24 (702MHz) | **512** |
| 原厂 | 2000 MHz | 2300 MHz | 2500 MHz | idx 24 (702MHz) | 1024 |
| 性能 | 2000 MHz | 2600 MHz | 2900 MHz | idx 20 (800MHz) | 1024 |

> **均衡档不硬限频**，只靠 `uclamp 512`——保留突发性能余量，日常最推荐。

### CLI

```bash
CTL=/data/adb/modules/perf_ctl/scripts/ctl.sh

sh $CTL status                                   # key=value 状态
sh $CTL apply <p0max> <p4max> <p7max> <gpu_idx> [oiface_1|0] [uclamp_max]
sh $CTL uclamp <64-1024>
sh $CTL oiface {on|off}
sh $CTL reset                                    # 恢复出厂
sh $CTL presets                                  # 列出预设
sh $CTL setboot <0|1>                            # 开机自启
sh $CTL dstart | dstop | dstat                   # 守护进程
```

### 关于 oiface（厂商调度服务）

**不需要停。** 实测：

| 场景 | 时长 | 结果 |
|---|---|---|
| 8 线程满载 | 20 s | `max_freq` / `uclamp` / GPU 全部纹丝不动 |
| 息屏 Dozing ↔ 亮屏 Awake | 35 s / 17 次采样 | 不变 |
| 打开/切换设置 App | 10 s | 不变 |

关键：**这些测试期间守护进程是关闭的**，所以「值没变」证明是 oiface 根本没碰这些节点。

停掉 oiface 反而会丢掉厂商的触控/游戏 boost。WebUI 里的开关只作兜底。

---

## 关键实测数据

### uclamp 能效（8 线程 × 3M，统一口径）

| 配置 | uclamp | 功耗 | 耗时 | 能耗 | 吞吐 |
|---|---|---|---|---|---|
| 原厂 2000/2300/2500 | 1024 | 10.97 W | 9.9 s | 108.7 J | 2.42 M/s |
| 原厂 + uc512 | 512 | 8.21 W | 10.0 s | **82.2 J** | 2.40 M/s |
| 原厂 + uc384 | 384 | 6.16 W | 12.3 s | 75.7 J | 1.95 M/s |
| 原厂 + uc256 | 256 | 3.34 W | 19.2 s | 64.3 J | 1.25 M/s |
| 省电 1200/1400/1400 + uc256 | 256 | 3.03 W | 20.2 s | **61.3 J** | 1.19 M/s |
| 性能 2000/2600/2900 | 1024 | 13.58 W | 9.9 s | 134.7 J | 2.42 M/s |

### 单线程 × 8M

| 配置 | 能耗 |
|---|---|
| 原厂 uc1024 | 54.2 J |
| 原厂 + uc512 | **42.1 J** |
| 原厂 + uc384 | 47.3 J |
| 原厂 + uc256 | 48.1 J |

**压得越狠越省电是错的**——存在 race-to-idle 拐点（1500–1800 MHz 附近）。

### 待机

三档限频待机电流只差 **3.6%**。限频治不了待机耗电，必须治后台。

---

## 文档

完整调研记录见 [docs/真我GT7-调优调研记录.md](docs/真我GT7-调优调研记录.md)，包含：

1. 设备与系统信息
2. CPU 架构与调频节点
3. oiface —— 厂商限频真凶
4. uclamp —— ✅ 有效（含一次重大自我纠错）
5. GPU 调频
6. 内存与 ZRAM 深度分析
7. swapfile 与 OPPO nandswap（8.5 GB zram1 元凶）
8. 内核限制与不可用项
9. perf_ctl 模块设计与实现（含踩坑记录）
10. 治耗电的优先级建议
11. 未解决问题

---

## 已知限制

| 项目 | 状态 | 原因 |
|---|---|---|
| sched_ext / scx BPF 调度器 | ❌ | 内核缺 `CONFIG_SCHED_CLASS_EXT` |
| GPU 直接锁频 | ❌ | devfreq governor = `dummy`，GED 固件接管 |
| 热控 `min_throttle_freq` | ❌ | 内核层只读 |
| `extra_free_kbytes` | ❌ | 此内核无该节点 |

---

## 免责声明

所有内容基于**单台设备**实测，不保证适用于其他机型/系统版本。
模块直接修改内核调度参数，**风险自负**，出问题用 `sh ctl.sh reset` 或卸载模块恢复。

## License

MIT
