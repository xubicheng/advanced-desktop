# AD — 鼠标形态的无屏微型计算机

**一句话：把一台计算机做进鼠标里。没有屏幕，用语音进出，屏幕是可选外设。**

> 现状：**设计方案阶段（v4），未采购、未下单，没有可运行的样机。**
> 这不是成品仓库，是一份把「能不能做、要妥协什么」算清楚的工程档案。

---

## 这是什么

AD = Advanced Desktop，一个 DIY 研究项目：

- **硬件**：BeagleBone Black（L1 板级开源）塞进 132×76×40mm 的真鼠标外壳，重 250–300g；
- **交互**：按住说话 → 云端 STT → LLM → 云端 TTS → 喇叭播报；自身位移驱动光标；
- **屏幕**：**可选**。要么 BBB 用 micro-HDMI 直出 720p，要么由 Android 手机把 AD 自己的画面投到你的 PC 显示器上；
- **软件**：一份 Rust 核心 + 两个渲染器（Android Canvas / BBB egui）+ 一个 PC 端 Receiver（只显示帧、只注入鼠标）。

**Windows / Linux 上跑的不是「AD 的另一个版本」，只是「一台显示器 + 一只被遥控的鼠标」。**

---

## 当前阶段

| 项 | 状态 |
|---|---|
| 硬件方案 | ✅ 定稿（v3）：BBB + 720p + 成品 USB 鼠标模块 + DC 5V/4A |
| 投屏方案 | ✅ 定稿（v4）：自渲染 + 自有 Receiver（MJPEG over TCP），scrcpy 兜底 |
| Android 最小链路 | ⬜ 未开始（计划 2 周） |
| 投屏 + 反向指针 | ⬜ 未开始（计划 W3–W4） |
| BBB 硬件端 | ⬜ 未开始（等板） |
| 采购 | ⬜ **未下单**（清单已出） |

## 下一步

1. 询价 BeagleBone Black（买不到就走 BBB Wireless）；
2. 按 [Android 先行周计划](docs/v3/Android-先行-周计划.md) 跑 W1–W2 语音链路；
3. W3 投屏、W4 反向指针；
4. 硬件端最后接。

---

## 文档索引

| 文档 | 看什么 |
|---|---|
| [**v4 方案（当前）**](docs/v4/AD-鼠标形无屏微型计算机-设计方案-v4.md) | 概念模型、投屏三方案取舍、数据流图、反向输入、息屏实测 |
| [v3 方案（硬件基线）](docs/v3/AD-鼠标形无屏微型计算机-设计方案-v3.md) | 六项连带代价、720p、USB Hub、供电、散热重算、验收表 |
| [Android 先行周计划](docs/v3/Android-先行-周计划.md) | 2 周排期 + 15 条验收线 |
| [许可清单](docs/v3/许可清单.md) | 组件许可、GPL 隔离、模型权重核实状态 |
| [采购清单（淘宝优先）](docs/v3/采购清单-淘宝优先.md) | 表 A 淘宝 / 表 B 线下 / 总预算 |
| [MVP 手工样品清单](docs/MVP-checklist/MVP-手工样品实施清单.md) | 买料 → 焊 → 装 → 测，每步通过标准 |
| [**决策记录 DECISIONS**](docs/DECISIONS.md) | D1–D5 为什么这么定，以及没关闭的问题 |
| [变更记录 CHANGELOG](docs/CHANGELOG.md) | v1→v4 每次改了什么、为什么、推翻了什么 |
| [文档总索引](docs/README.md) | 全部文档的导航 |

---

## 三个必须先知道的硬事实

1. **单核 1GHz + 512MB 跑不动本地语音。** 3 秒音频在 BBB 上要 9–15 秒才出结果。所以语音默认走云端，本地只留 6–10 条预录提示音。这不是偷懒，是算力事实。
2. **720p 是上限。** TDA19988 与单核显示子系统撑不住 1080p 的日常使用，UI 按 1280×720 设计（正文 ≥24px、按钮 ≥64px、禁双栏）。
3. **鼠标会很重（250–300g）。** 常规重鼠约 120–140g。这是「L1 开源板 + 真鼠标形态」的必然代价，缓解手段是重心压在掌心，不是减重。

---

## 在手机上看进度

**客户端的账号同步不是本仓库能控制的**——你在 A 电脑上的对话不会自动出现在 B 电脑或手机上。

本项目的跨设备查看机制是：**GitHub 公开仓库 + 每次更新即提交。**

手机上：

1. 用手机浏览器打开 <https://github.com/xubicheng/advanced-desktop>；
2. 点 **Commits** 看最近改了什么（每条提交信息都写清改了什么）；
3. 看根目录 **README** 的「当前阶段」表格 —— 这张表每次更新都会改；
4. 想看细节就点 `docs/` 下的 Markdown，GitHub 手机版能直接渲染。

不需要装 App，不需要登录。

---

## 目录结构

```
advanced-desktop/
├─ docs/        v1 / v2 / v3 / v4 版本化方案 + CHANGELOG + DECISIONS + README 索引
├─ software/    核心（Rust）/ Android 壳 / BBB 壳 / PC Receiver
├─ hardware/    外壳（FreeCAD/OpenSCAD）、转接板（KiCad）、装配图
├─ bom/         采购清单 CSV（淘宝 / 线下）
└─ logs/        对话纪要（已脱敏）
```

---

## 许可

- 代码 **MIT**（[LICENSE-CODE](LICENSE-CODE)）
- 硬件设计 **CERN-OHL-S-2.0**（[LICENSE-HARDWARE](LICENSE-HARDWARE)）
- 文档 **CC-BY-4.0**（[LICENSE-DOCS](LICENSE-DOCS)）
- 说明与第三方组件：[LICENSE](LICENSE)、[THIRD-PARTY.md](THIRD-PARTY.md)

## 兼容基线

| 平台 | 支持 |
|---|---|
| Windows | 10 1809（17763）+、Windows 11 |
| Linux | glibc ≥ 2.28：Ubuntu 20.04/22.04/24.04、Rocky 8/9、Alma 8/9 |
| Linux（不支持） | **CentOS 7（glibc 2.17，已 EOL）**、CentOS 8（已 EOL） |
| Android | 8.0（API 26）+ |
| macOS / iOS | 不做 |

---

*这是一个仍在设计阶段的 DIY 项目。所有价格、供货、性能数字凡未实测的都已标注「需询价 / 需实测」。*
