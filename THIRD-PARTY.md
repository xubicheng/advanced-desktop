# 第三方组件（THIRD-PARTY）

> 原则：**核心程序只链接 MIT / Apache-2.0 / BSD 类宽松许可的组件；GPL 组件只能以独立进程 / CLI 方式调用。**
> 核实日期：2026-11-06（仓库默认分支快照）。落地时必须锁定 commit 后重核。
> 详细判断见 [docs/v3/许可清单.md](docs/v3/许可清单.md)。

---

## 1. 运行时依赖（Rust，链接进核心）

| 组件 | 版本 | 许可证 | 用途 | 备注 |
|---|---|---|---|---|
| tokio | 1.x | MIT | 异步运行时 | |
| serde / serde_json | 1.x | MIT OR Apache-2.0 | 序列化 | |
| reqwest | 0.12.x | MIT OR Apache-2.0 | HTTP | |
| rustls | 0.23.x | Apache-2.0 OR ISC OR MIT | TLS | 避免 OpenSSL |
| ring | 0.17.x | ISC + OpenSSL 例外 | rustls 加密后端 | **需保留例外条款原文** |
| opus（libopus 静态） | 1.4+ | BSD-3-Clause | 语音编解码 | |
| rubato | 0.15.x | MIT | 重采样 | |
| tracing | 0.1.x | MIT | 日志 | |
| thiserror / anyhow | 1.x | MIT OR Apache-2.0 | 错误处理 | |
| jni | 0.21.x | MIT OR Apache-2.0 | Android 绑定 | |
| cpal | 0.15.x | MIT OR Apache-2.0 | 音频 I/O | |
| jpeg-decoder | 0.3.x | MIT | Receiver 解码 | |
| winit | 0.30.x | Apache-2.0 | Receiver 窗口 | |
| softbuffer | 0.4.x | MIT OR Apache-2.0 | Receiver 位图 blit | 零 GPU 依赖 |

## 2. Android 端

| 组件 | 许可证 | 备注 |
|---|---|---|
| Kotlin stdlib / coroutines | Apache-2.0 | |
| AndroidX（core / activity / lifecycle） | Apache-2.0 | |
| Jetpack Compose | Apache-2.0 | |
| androidx.security:security-crypto | Apache-2.0 | 存 API Key |

**不引入**：Google Play Services、Firebase、任何云厂商闭源语音 SDK（一律走 HTTPS）。

## 3. 语音模型与运行时（状态：逐项核实）

| 组件 | 许可证 | 状态 |
|---|---|---|
| sherpa-onnx | **Apache-2.0**（已抓取 LICENSE 确认） | ✅ |
| whisper.cpp | **MIT**（已抓取确认） | ✅ |
| FunASR / Paraformer 运行时 | **MIT**（已抓取确认） | ✅ |
| SenseVoice（代码） | **MIT**（已抓取确认） | ✅ 代码；**权重另核** |
| VITS（代码） | **MIT**（已抓取确认） | ✅ 代码；**权重另核** |
| piper（rhasspy） | **MIT**（代码，已抓取确认） | ❌ **禁用**：依赖 espeak-ng |
| espeak-ng | **GPL-3.0**（已抓取 COPYING 确认） | ❌ **禁止链接** |
| ONNX Runtime | MIT（官方长期声明） | ⚠️ 锁版本时再核 |

### 模型权重（**未核实 = 禁止默认商用**）

| 权重 | 状态 |
|---|---|
| Whisper 官方权重（tiny/base/small） | **未核实**（代码 MIT 不等于权重 MIT） |
| whisper.cpp 社区 GGML 量化权重 | **未核实**（各家不同） |
| SenseVoice-Small | **未核实**（ModelScope 模型页许可 ≠ GitHub LICENSE） |
| Paraformer 中文 | **未核实** |
| VITS 中文（第三方训练） | **未核实，高风险** |
| sherpa-onnx 发布的模型包 | **逐个核实**（同页面可能混有 CC-BY-NC） |
| piper voices | **逐个核实**（常见 CC BY-NC，不可商用） |

> 本项目 **P0 不使用任何本地语音模型**（单核 BBB 跑不动，见 v3 §3.4）。上表用于将来若引入时自查。

## 4. 构建工具（不传染产出物）

| 工具 | 许可证 | 说明 |
|---|---|---|
| Cargo / rustc / cargo-ndk | MIT OR Apache-2.0 | |
| Gradle | Apache-2.0 | |
| Android SDK / NDK | 专有许可 | 不进仓库 |
| KiCad | GPL-3.0 | **工具输出不构成衍生作品** |
| FreeCAD | LGPL-2.1+ | 同上 |
| OpenSCAD | GPL-2.0+ | 同上 |

## 5. 硬件与系统

| 项 | 许可证 |
|---|---|
| BeagleBone Black 板级设计 | OSHW（BeagleBoard.org 发布） |
| Debian（BBB 系统） | 混合（GPL/LGPL/MIT/BSD），作为发行版与核心是聚合关系 |
| Linux 内核 | GPL-2.0（本项目**不写内核模块**） |

---

*若发现本表有遗漏或许可误判，请开 Issue。项目优先保证「许可干净」高于「功能多」。*
