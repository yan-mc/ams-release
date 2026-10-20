# ams-release

AMS 发布与更新：`ams-update/1` 清单签名/校验工具、发布脚本与示例。

## 目录

| 路径 | 说明 |
|---|---|
| `tools/manifest.py` | Ed25519 清单签名/校验 CLI（keygen/sign/verify/init） |
| `schemas/ams-update-1.schema.json` | 清单 JSON Schema（草案） |
| `tests/test_manifest.py` | 签名/篡改/回滚 sequence 测试 |
| `examples/` | 示例清单、演示密钥对（**非生产**） |

## 快速开始

```powershell
python tools/manifest.py keygen --out keys
python tools/manifest.py init --out examples/manifest.json
python tools/manifest.py sign examples/manifest.json --key keys/private.pem --out examples/manifest.signed.json
python tools/manifest.py verify examples/manifest.signed.json --pub keys/public.pem --min-sequence 1
```

## 规则

- 私钥只放 CI Secret/离线保管，**不要提交**；`keys/` 已在 .gitignore。
- 签名覆盖“除 signature 外的完整清单”，JSON 规范化（sort_keys + 无空格）。
- `sequence` 单调递增，启动器用它拒绝回滚；`withdraw` 用于撤回组件。
- 正式密钥生成后，把 `public.pem` 内置到启动器。
## 备份脚本

```powershell
pwsh tools/backup.ps1 -Workspace "F:/Deepseek_harness/AI音乐处理/08_项目代码"
```

对 7 个仓库执行 `git bundle --all` 并 verify，输出到 `_backups/`。
## 打包脚本

```powershell
# 默认曼波 voicepack（zip，本地生成，不进 Git）
pwsh tools/build-voicepack.ps1 -Source "F:/ai歌曲/0 曼波"

# 暂存发布目录（启动器安装包 + voicepack + stage-manifest）
pwsh tools/stage-release.ps1 -Out "F:/Deepseek_harness/AI音乐处理/09_发布/staging"
```

产物写入 `09_发布/`（本地发布物，不入库）；`stage-manifest.json` 记录每个文件的 size/sha256。
## 组件 feed（M2）

```powershell
# 生成 3 个真实组件 + 已签名 feed（默认输出 09_发布/updates）
pwsh tools/build-components.ps1 -Out "F:/Deepseek_harness/AI音乐处理/09_发布/updates"

# 暂存发布（自动含 0.2.0 安装包、voicepack、updates feed/packages 与 stage-manifest）
pwsh tools/stage-release.ps1 -Out "F:/Deepseek_harness/AI音乐处理/09_发布/staging"
```

启动器用 `AMS_COMPONENTS_FEED` 指向 `updates/ams-components.json`；本地包 URL 使用 `file:///`，生产环境替换为 HTTPS 服务器。

## 注意（私有仓库）

GitHub 仓库已改为 Private，release 资产不能被匿名下载；M2 的更新中心使用本地/离线 feed，公网更新服务在 M3 部署。
