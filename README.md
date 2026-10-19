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
