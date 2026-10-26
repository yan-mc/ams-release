# ams-release / qa —— AMS Studio 发布与验收脚本

所有脚本只读运行（除自身输出目录），默认输出到 `F:/Deepseek_harness/AI音乐处理/_接管审计/qa/<时间戳>/`。

| 脚本 | 用途 | 现状 |
|---|---|---|
| `run-h4.ps1` | **H4 总验收入口**：版本矩阵、H2 feed 2049 / H3 feed 2050、Ed25519 验签、setup/kernel/gateway/plugin 哈希、Gateway pytest、release pytest；可选 `-AmsHome` 做 Gateway 健康检查。输出 results.json + summary.md。 | 新增（替代 run-h3.ps1） |
| `ui-cdp.ps1` | **H3/H4 UI 验收**：Edge CDP 逐页签点击 AMS 音乐页面（14 个页签），断言内容、截屏、收集 console 错误。 | 新增 |
| `h4-gpu-e2e.ps1` | **H3/H4 GPU 全链路**：通过 Gateway API 提交 RVC/pymss/TTS/训练/评测/混音任务并校验产物。 | 待补 |
| `run-h3.ps1` | 旧 H3 入口（引用已删除的 09_发布/_阶段G 与 sequence 2045）。 | **已废弃，勿用** |
| `run-installer-smoke.ps1` | 安装器静默安装/卸载 smoke（旧）。 | 待更新到 1.0.0-rc.1 |

## 当前发布真值（2026-10-26）

- H2（latest）：v0.2.1，feed **2049**，feed sha256 `FD026F77…88D00`，setup `45438A12…04D8`
- H3（prerelease）：v1.0.0-rc.1，feed **2050**，feed sha256 `3BA9243C…BE9B`，setup `0AF08BE4…A931`
- 完整矩阵见项目根 `CURRENT_STATE.md`；发布物料见 `09_发布/当前/`。

## 常用命令

```powershell
# H4 总验收（不含 UI/GPU）
pwsh -File .\run-h4.ps1 -AmsHome 'F:\AMS-H4-H3\data'

# UI 14 页签（Kernel 已启动）
pwsh -File .\ui-cdp.ps1 -KernelUrl 'http://127.0.0.1:10567' -CdpPort 9223

# 只验签一份 feed
python ..\tools\manifest.py verify 'F:\Deepseek_harness\AI音乐处理\09_发布\当前\H3_1.0.0-rc.1_feed2050\ams-components.json' --pub ..\examples\keys\public.pem --min-sequence 2050
```
