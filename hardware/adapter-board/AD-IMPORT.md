# 在 Altium Designer 中打开本板（AD 导入说明）

## 先说结论

本包**不含 .PcbDoc**。原因：`.PcbDoc` 是 Altium 的封闭二进制格式，我这边没有 Altium Designer，用第三方工具硬转会得到"能生成但不敢拿去打板"的文件（网络、铺铜、封装关联都可能丢）。

但 **Altium 自带 KiCad 导入器**（官方支持 KiCad 8 以下版本，本板是 KiCad 7 格式），导入后另存即可得到原生 `.PcbDoc`，全程约 1 分钟，不需要装 KiCad。

## 导入步骤（AD 20 及以上）

1. `File` → `Import Wizard`（部分版本为 `File` → `Import` → `KiCad`）。
2. 点 `Next`，文件类型勾选 **KiCad Design Files**，再 `Next`。
3. `Add` 选择本目录下的 **AD-Carrier-Lite-v0.1.kicad_pcb**（同目录的 `.kicad_pro` 会被自动关联；若向导要求工程文件，选 `.kicad_pro`）。
4. 指定输出目录 → `Next` → `Finish`。
5. 打开生成的 `.PcbDoc`，执行：
   - `Tools` → `Polygon Pours` → `Repour All`（导入后铺铜必须重灌一次）；
   - 若板框没有自动识别：选中板框线 → `Design` → `Board Shape` → `Define from selected objects`；
   - `Design` → `Board Layers & Colors` 确认是 2 层。
6. 核对无误后 `File` → `Save As` 存成 `.PcbDoc`，这就是你们要的 AD 格式。

## 导入后必须核对的 6 项

| 项 | 应为 |
|---|---|
| 层数 | 2 层（Top / Bottom） |
| 板框 | 60 × 45 mm 矩形 |
| 安装孔 | 4 个 NPTH，孔径 2.7 mm，M2.5 |
| 网络 | 6 个：5V_IN、FUSED、+5V、GND、LED_A、PTT |
| 过孔 | 3 个，0.8/0.4 mm |
| 铺铜 | Top/Bottom 双面 GND，重灌后无孤岛 |

## 已知差异（不是错误）

- **丝印字体**：KiCad 笔画字体导入 AD 后会被替换，字宽略有变化，不影响制板；
- **3D 模型不带入**：结构核对请用包内 `AD-Carrier-Lite-v0.1.step`；
- **设计规则**只带入基本项（线宽/间距 0.3 mm），需要的话在 AD 里按 FAB-NOTES 重建；
- **封装名**会带 KiCad 库前缀，属正常现象。

## 如果导入失败

1. 确认 AD 版本 ≥ 20；
2. 直接用 `gerber/` 打板，**打板本身不需要 AD**——Gerber + 钻孔 + BOM + 坐标就是工厂要的全部；
3. AD 只用于评审和改板，不参与生产。
