# software/ — 一份核心，两个渲染器，一个 Receiver

```
software/
├─ core/        Rust crate（MIT）—— 唯一真身：会话状态机 / 音频 / STT / LLM / TTS / 指针事件
├─ android/     Kotlin + Compose 壳（Apache-2.0）—— 渲染器 R2 + 投屏发送 + OTG HID 读取
├─ bbb/         Rust 壳（MIT）—— 渲染器 R1（egui）+ ALSA + uinput
└─ receiver/    PC 端接收器（MIT）—— 显示 JPEG 帧 + 注入指针（Win SendInput / Linux uinput）
```

## 边界（不要越界）

| 层 | 能做什么 | 不能做什么 |
|---|---|---|
| `core` | 会话、语音、AI、UI 状态模型、`PointerEvent` | **不碰平台 API**（无 Android、无 ALSA、无 winit） |
| `android` | 渲染、投屏、录音、USB HID 读取、前台服务 | 不实现业务逻辑 |
| `bbb` | 渲染、HDMI、音频 I/O、uinput | 不实现业务逻辑 |
| `receiver` | 显示帧、注入指针 | **不含任何 AD 逻辑** |

## 状态

**当前为空骨架。** 代码尚未开始，计划见 [docs/v3/Android-先行-周计划.md](../docs/v3/Android-先行-周计划.md) 与 [docs/v4 §8](../docs/v4/AD-鼠标形无屏微型计算机-设计方案-v4.md)。

## 核心 C ABI（约定，先定接口再写实现）

```c
typedef struct AdCallbacks {
    void (*on_event)(const char *json, void *user);
    void (*on_pcm)(const int16_t *pcm, int frames, int rate, void *user);
} AdCallbacks;

void *ad_core_new(const char *config_json, AdCallbacks cb, void *user);
int   ad_core_start_listen(void *h);
int   ad_core_end_listen(void *h);
int   ad_core_push_pcm(void *h, const int16_t *pcm, int frames, int rate);
int   ad_core_cancel(void *h);
int   ad_core_set_mode(void *h, int mode);   /* 0=auto 1=cloud 2=local-rule */
int   ad_core_get_state(void *h);
void  ad_core_free(void *h);
```

## 许可

全部 MIT / Apache-2.0。第三方清单见 [THIRD-PARTY.md](../THIRD-PARTY.md)。
**禁止引入 GPL/AGPL 依赖。**
