# AD · Android 先行周计划（2 周最小链路）

> **v4 修订提示**：本文 W1–W2 的内容仍然有效，但两处需按 [v4 方案](../v4/AD-鼠标形无屏微型计算机-设计方案-v4.md) §8 执行：
> ① W2 的 UI 改为「渲染到 Bitmap」（为投屏做准备），不再是「只上屏」；
> ② 原「第 3–4 周桌面壳」作废，改为 **W3 投屏打通、W4 反向指针 + 息屏实测**。
> 也就是说：**Windows/Linux 端不是 AD 的另一个版本，而是 Receiver（显示帧 + 注入指针）**。

| 项目 | 内容 |
|---|---|
| 版本 | v3.0 |
| 日期 | 2026-11-06 |
| 目标 | 2 周内在 Android 上跑通「按键说话 → 录音 → STT → LLM → TTS → 播放 + 进度播报」整条链 |
| 关联 | [v3 方案](AD-鼠标形无屏微型计算机-设计方案-v3.md)、[许可清单](许可清单.md)、[DECISIONS.md](../DECISIONS.md) |

> 本文的「周」按 **每周可投入 10–15 小时** 估算（业余时间，含调试）。
> 若每周只能投 1–2 小时，下面 2 周的内容实际需要 **8–12 周**——这不是悲观，是上一版参考材料（豆包方案）最大的错。

---

## 0. 先说清楚：为什么 Android 先行

1. **零硬件依赖**：不用等 BBB 到货，不用等外壳打印，手机就是现成的 ARM Linux 设备；
2. **链路最快闭环**：Android 的录音/播放/网络/UI 都是成熟 API，能在一周内把「能说话」做出来；
3. **核心代码可以搬家**：Rust 核心编成 `cdylib`，Android 走 JNI，桌面走原生链接，BBB 走同一份 `.so`——**先写的核心不是丢弃品**；
4. **风险前置**：STT/LLM/TTS 的选型、延迟、成本、许可证这四个真问题，在手机上暴露比在 BBB 上暴露便宜得多。

---

## 1. 技术栈（锁定）

| 层 | 选型 | 许可证 | 说明 |
|---|---|---|---|
| 核心 | **Rust 1.8x**，`cdylib`，C ABI + 手写 JNI | MIT（我方） | 依赖全部 MIT/Apache/BSD，见许可清单 |
| 异步 | `tokio`（rt-multi-thread，Android 上开 2 worker） | MIT | |
| HTTP | `reqwest`（rustls，**不用 openssl**） | MIT/Apache-2.0 | rustls 避免 OpenSSL 交叉编译地狱 |
| 音频编解码 | `opus`（`audiopus` 或 `opus-rs`，静态链接 libopus） | BSD-3（libopus） | 16 kHz 单声道，20 ms 帧，24 kbps |
| 重采样 | `rubato` | MIT | 48k → 16k |
| JSON | `serde_json` | MIT/Apache-2.0 | |
| 日志 | `tracing` + `tracing-android` | MIT | |
| Android 壳 | **Kotlin 2.x + Jetpack Compose** | Apache-2.0 | minSdk 26 / targetSdk 35 |
| 录音 | `AudioRecord`（16 kHz / 16-bit / mono） | Android 平台 | 不用 MediaRecorder，避免文件落盘与延迟 |
| 播放 | `AudioTrack`（流式 PCM） | Android 平台 | TTS 边下边播；不用 ExoPlayer（首包延迟高） |
| 前台服务 | `ForegroundService` + `foregroundServiceType="microphone"` | Android 平台 | API 34 强制 |
| 存储 | `EncryptedSharedPreferences` | Apache-2.0 | 存 API Key |
| 构建 | Gradle 8.x + `cargo-ndk` | Apache-2.0 / MIT | 输出 `arm64-v8a` + `armeabi-v7a` |
| 云服务 | **可插拔 Provider 抽象**，先接 1 家 | — | 见 §4 |

**明确不用：**
- ❌ Flutter（多一层 Dart 运行时，与「一套核心」目标重复，且 Android 音频底层仍要写 platform channel）
- ❌ React Native（同上，且 JS 桥延迟对语音不友好）
- ❌ Go + gomobile（AAR 体积 10–20 MB、JNI 调用开销、GC 停顿；参考材料推荐 Go，我方不采纳，理由见 CHANGELOG）
- ❌ 本地 STT/TTS 模型（Android 手机虽然跑得动，但和 BBB 端行为不一致，会掩盖真实问题；**P0 只做云端**）

---

## 2. 代码结构

```
software/
├── core/                        # Rust 核心（MIT）
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs               # C ABI 导出（extern "C"）
│       ├── jni_bridge.rs        # JNI 绑定（仅 android feature）
│       ├── session.rs           # 一次对话的状态机
│       ├── audio/
│       │   ├── capture.rs       # 16k 采集缓冲、VAD
│       │   ├── resample.rs
│       │   └── opus_codec.rs
│       ├── stt/                 # trait SttProvider
│       │   ├── mod.rs
│       │   └── cloud_http.rs    # 先实现 1 家
│       ├── llm/
│       │   ├── mod.rs
│       │   └── openai_compat.rs # 兼容 OpenAI 协议的都走这里
│       ├── tts/
│       │   ├── mod.rs
│       │   └── cloud_stream.rs
│       ├── rule_engine.rs       # 本地固定指令（音量/暂停/静音…）
│       ├── event.rs             # on_event JSON 构造
│       └── net.rs               # 连通性探测、超时、重试
├── android/                     # Kotlin 壳（Apache-2.0）
│   ├── app/src/main/java/.../
│   │   ├── MainActivity.kt      # Compose UI（720p 规范）
│   │   ├── AdCore.kt            # JNI 声明 + 生命周期
│   │   ├── VoiceService.kt      # 前台服务（microphone 类型）
│   │   ├── AudioIo.kt           # AudioRecord / AudioTrack
│   │   ├── Notifier.kt          # 常驻通知 + 三个 Action
│   │   └── OemHelper.kt         # 厂商 ROM 引导页
│   └── app/src/main/cpp/        # 仅放 prebuilt libad_core.so 的包装
├── desktop/                     # Windows / Linux 桌面壳（MIT）
│   └── src-tauri/ or eframe/    # 见 v3 方案 §5.3，egui 定案
└── bbb/                         # BBB 端（v3 第三阶段，本文不展开）
```

**核心的 C ABI**（与 v3 方案 §5.2 一致，不重复展开）：

```c
void *ad_core_new(const char *config_json, AdCallbacks cb, void *user);
int   ad_core_start_listen(void *h);
int   ad_core_end_listen(void *h);
int   ad_core_cancel(void *h);
int   ad_core_set_mode(void *h, int mode);
int   ad_core_get_state(void *h);
void  ad_core_free(void *h);
```

---

## 3. 两周排期与验收标准

### 第 1 周：把「声音」跑通（哑链路）

**目标：能按键录音、能把音频发出去、能把音频收回来播放。LLM 先用固定回复。**

| 天 | 任务 | 产出 |
|---|---|---|
| D1 | 建仓、`cargo-ndk` 交叉编译 `arm64-v8a` 打通，空 `.so` 能被 Kotlin `System.loadLibrary` 加载 | `libad_core.so` 在真机上加载成功，`adb logcat` 看到 Rust 的 tracing 日志 |
| D2 | `AudioRecord` 采集 16 kHz PCM → 通过 JNI 传入 Rust → Rust 落 WAV 文件到 `filesDir` | 录 3 秒，用 Audacity 打开 WAV，波形正常、无削波 |
| D2 | 前台服务：`foregroundServiceType="microphone"`，5 s 内 `startForeground()` | 锁屏后仍能录音 10 min 不被杀 |
| D3 | 常驻通知 + 三个 Action（说话/取消/退出），通知点「说话」能触发录音 | 息屏状态下从通知栏触发一次完整录音 |
| D4 | opus 编码（24 kbps / 20 ms 帧）+ 封装，本地解码回放验证 | 编码→解码→播放，听感无明显失真 |
| D5 | 接 STT Provider（1 家），录音 → 上传 → 拿回文本 | 3 秒中文语音，识别结果与说话内容一致（≥ 90% 字准确） |
| D6 | 接 TTS Provider（1 家），文本 → 流式音频 → AudioTrack 播放 | 输入「今天南京天气怎么样」，3 秒内开始出声 |
| D7 | 拼哑链路：按键 → 录音 → STT → **固定回复** → TTS → 播放 | 端到端首音 ≤ 3.5 s，连续 20 次无崩溃 |

**第 1 周验收线（必须全绿才进第 2 周）：**

| # | 验收项 | 标准 |
|---|---|---|
| W1-1 | 真机加载 | `arm64-v8a` 与 `armeabi-v7a` 都能加载 |
| W1-2 | 录音质量 | 16 kHz / 16-bit / mono，无削波，本底噪声不明显 |
| W1-3 | 息屏存活 | 锁屏 10 min 后仍能录音（小米/华为/OPPO 至少 1 台实测通过） |
| W1-4 | STT 准确率 | 3 句测试语音，字准确率 ≥ 90% |
| W1-5 | TTS 首包 | 文本 → 首音 ≤ 1.5 s |
| W1-6 | 哑链路端到端 | 首音 ≤ 3.5 s，20 次无崩溃 |
| W1-7 | 内存 | 连续 20 次后 App RSS 增长 < 15% |

### 第 2 周：把「脑子」接上（真链路 + 降级 + UI）

| 天 | 任务 | 产出 |
|---|---|---|
| D8 | 接 LLM（OpenAI 兼容协议，流式），替换固定回复 | 流式 token 回调到 UI |
| D9 | 分句缓冲：LLM 流式输出按句号/问号切分，**逐句送 TTS 并播放**（关键：不要等全文） | 首音延迟从「全文生成后」降到「第一句生成后」 |
| D10 | 打断（barge-in）：播放中再按 PTT，立即 `ad_core_cancel`，停播放、停请求 | 打断响应 ≤ 300 ms |
| D11 | 规则引擎：音量加/减、静音、暂停、继续、取消、打开设置（10–15 条），命中则本地执行不出网 | 断网时这些指令仍可用 |
| D12 | 降级三级：网络探测（≤300 ms）→ 云端；超时 5 s → 「服务慢」；断网 → 预录提示音 + 离线标记 | 飞行模式下不卡、不崩，2 秒内给出反馈 |
| D13 | Compose UI 按 720p 规范落地：四态可视（听/想/说/错）、单列三区、96×96 PTT 按钮 | 截图对照规范逐项检查 |
| D14 | 常驻通知状态同步、错误提示、API Key 设置页（`EncryptedSharedPreferences`）、厂商 ROM 引导页 | |
| D14 | 回归 + 4 小时循环测试 | 无泄漏、无重启 |

**第 2 周验收线（= 里程碑验收）：**

| # | 验收项 | 标准 |
|---|---|---|
| W2-1 | 真链路端到端 | 「帮我说明天天气」→ 听到完整回答，首音 ≤ 3.5 s，总时长 ≤ 12 s |
| W2-2 | 流式分句生效 | 长回答（> 100 字）首音不晚于「第一句生成后 800 ms」 |
| W2-3 | 打断 | 播放中按 PTT，300 ms 内静音并回到「在听」 |
| W2-4 | 断网降级 | 飞行模式：按键后 ≤ 2 s 播报「网络不通」，不崩溃、不长时间无响应 |
| W2-5 | 息屏 | 锁屏 30 min 后，通知栏一键说话成功 |
| W2-6 | UI 规范 | 正文 ≥ 24 px、按钮 ≥ 64 px、单列、对比度 ≥ 7:1、无左右分栏 |
| W2-7 | 稳定性 | 4 h 循环 200 次，崩溃 0 次，RSS 增长 < 10% |
| W2-8 | 三机型 | 至少在 3 台不同厂商 ROM（如小米 / 华为 / 三星 或 OPPO）上通过 W2-4 与 W2-5 |

---

## 4. 云服务：先接 1 家，但抽象层先做好

**原则：不锁定供应商。** 核心里的 `trait SttProvider` / `trait LlmProvider` / `trait TtsProvider`，各做 1 个实现（`openai_compat.rs` 同时覆盖 OpenAI 兼容协议的 LLM）。

**必须抽象出来的差异点：**

| 差异 | 处理 |
|---|---|
| 鉴权方式 | `AuthStrategy`：Bearer / Query Key / 签名 |
| 音频格式 | 输入：opus / wav / mp3；输出：pcm / mp3 / opus。统一在核心内转 PCM |
| 流式协议 | SSE / WebSocket / chunked。统一转为 `on_event` |
| 超时与重试 | `net.rs` 统一：连接 3 s、首包 5 s、总 60 s；重试 1 次（仅幂等请求） |
| 计费口径 | 记录 token / 秒数到本地日志，供用户自查 |

**未定项（O2/O3）：** 具体用哪家云、Key 谁的、怎么计费——**这两周不解决，用用户自填 Key 的方式先跑通**。对外发布前必须改成代理服务，见 DECISIONS.md。

---

## 5. 之后的两步（不在两周内）

### 第 3–4 周：Windows / Linux 桌面壳

- 同一份 `core`，编成静态库/动态库，egui 壳直接调用（不需要 JNI）。
- 交付：Windows 单 exe（Win10 1809+ 实测）、Linux `.deb` + AppImage（Ubuntu 22.04 上构建，glibc 2.28 基线）。
- 验收：与 Android 壳功能对齐（可用同一份 V10–V13 验收表），核心零改动。

### 第 5 周起：BBB 硬件端

- 同一份 `core` 编 `armv7`（`arm-unknown-linux-gnueabihf`，BBB 是 32 位 ARMv7 + 硬浮点）。
- 壳层用 egui（720p 全屏）+ ALSA（`cpal`）+ USB 声卡。
- 接 PTT GPIO（`gpiod`，MIT）、指示灯、USB 鼠标模块的 HID 事件。
- 验收：v3 方案 §8 的 V1–V14 全表。

---

## 6. 这一阶段最大的三个坑（提前说）

| # | 坑 | 现象 | 预防 |
|---|---|---|---|
| 1 | **Android 14 前台服务限制** | 从后台启动 `startForegroundService` 抛 `ForegroundServiceStartNotAllowedException` | 只能从**可见 Activity** 或**通知 Action** 启动；`startForeground()` 一定在 5 s 内调用；`foregroundServiceType="microphone"` 必须声明，且 `RECORD_AUDIO` 权限必须在**启动服务前**已授予 |
| 2 | **厂商 ROM 杀后台** | 息屏 10 min 后录音中断，无报错 | 三机型实测 + 引导页（小米自启动/无限制省电、华为手动管理、OPPO/vivo 后台高耗电+自启动、三星从未休眠应用） |
| 3 | **JNI 线程与回调** | Rust 回调到 Kotlin 时 `JNIEnv` 失效导致崩溃 | 回调必须 `AttachCurrentThread` + 全局 `JavaVM` 引用；或用「Rust 写队列，Kotlin 侧轮询」避免跨线程回调 |

---

## 7. 依赖与许可证自查（本阶段就锁死）

| 依赖 | 许可证 | 是否链接进核心 | 备注 |
|---|---|---|---|
| tokio / serde / reqwest / rustls | MIT 或 Apache-2.0 | 是 | 安全 |
| `ring`（rustls 的加密后端） | **ISC + 部分 OpenSSL 例外** | 是 | 需在 THIRD-PARTY 中单列，见许可清单 |
| libopus（`audiopus_sys`） | BSD-3-Clause | 是（静态） | 安全 |
| rubato | MIT | 是 | |
| tracing | MIT | 是 | |
| Kotlin / Compose / AndroidX | Apache-2.0 | 是（APK 内） | 安全 |
| `androidx.security:security-crypto` | Apache-2.0 | 是 | |
| 云 STT/TTS SDK | 闭源 | **不链接** | 一律走 HTTP，不用厂商 SDK，避免闭源二进制进 APK |
| WebRTC AEC3（若后续加） | BSD-3 | 是 | 安全 |

**红线：本阶段不引入任何 GPL/AGPL/SSPL 依赖。** 若某个云服务只提供 GPL 的 SDK，则改为纯 HTTP 调用，不引入 SDK。

---

## 8. 里程碑汇报点

按用户要求，本计划**成型即报**（已在本次交付中汇报）。下一个汇报点：

- W1-7 全绿 → 报「哑链路打通」+ 实测延迟数字；
- W2-8 全绿 → 报「Android 最小链路完成」+ 三机型兼容表 + 首音延迟分布；
- 仓库推送成功 → 立即报（不等全部文档写完）。
