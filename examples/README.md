# ams-release/examples —— 更新清单与签名示例

> 用途：给启动器更新中心 / CI 生成脚本 / 单元测试提供“真实可验签”的参考样例。
> 全部为**示例数据**：除注明“真实本机构建产物”的条目外，其余组件的 `sha256`/`size` 为占位值，正式发布前由 CI 按真实产物替换。

## 文件

| 文件 | 说明 |
|---|---|
| `manifest.json` | **7 组件** `ams-update/1` 清单示例：launcher / kernel / plugin.core / service.gateway / service.pymss / tool.ffmpeg / catalog.models |
| `manifest.signed.json` | 上述清单的 Ed25519 签名结果（签名覆盖“除 signature 外的完整清单”） |
| `catalog.models-2026.10.19.json` | `catalog.models` 组件的示例索引（清单里引用它的真实 size/sha256） |
| `keys/private.pem`、`keys/public.pem` | **演示密钥对**（本机生成、被 .gitignore 忽略；仅用于本地跑通 sign/verify，**不是生产密钥**） |

## 清单要点

- `schema`: `ams-update/1`；`channel`: `stable`；`sequence`: `1287`（单调递增，启动器据此拒绝回滚）；`min_launcher`: `0.1.4`。
- `withdraw`: `["plugin.ams.music.core@0.1.3"]`（命中后不再提示该版本；已装则提示回退）。
- 组件字段：`id / kind / version / url / mirrors / size / sha256 / signature_key_id / requires / notes`；`kind` 属于 schema 枚举（launcher/kernel/plugin/service/tool/catalog）。
- `requires` 用于依赖求解：`kernel` 依赖 `launcher` 与 `plugins_api`；`plugin.*` 声明 `kernel`+`services`；`service.*` 声明 `gateway`/`runtime`/模型 catalog 版本。
- 真实值条目：`launcher`（本机 NSIS 0.1.4，1,448,763 B）、`plugin.ams.music.core`（ams-plugin-core-0.2.0.tgz，8,037 B）、`catalog.models`（本目录 catalog 文件的真实哈希）。
- 占位条目（notes 已注明）：`kernel`（待 M1 打包）、`service.gateway` / `service.pymss`（待服务打包）、`tool.ffmpeg`（LGPL 构建待锁定版本）。

## 签名 / 校验命令（本机实测通过）

```powershell
cd F:/Deepseek_harness/AI音乐处理/08_项目代码/ams-release

# 1) 签名
python tools/manifest.py sign examples/manifest.json --key examples/keys/private.pem --out examples/manifest.signed.json
# -> signed -> examples/manifest.signed.json

# 2) 校验（防回滚：要求 sequence >= 1287）
python tools/manifest.py verify examples/manifest.signed.json --pub examples/keys/public.pem --min-sequence 1287
# -> OK: signature valid, schema ok, sequence=1287, components=7

# 3) 低于已见 sequence 应被拒绝（退出码 5）
python tools/manifest.py verify examples/manifest.signed.json --pub examples/keys/public.pem --min-sequence 2048

# 4) 篡改任意字段后验签应失败（退出码 1）
#    做法：改 components[0].version 后另存，再 verify

# 5) 工具自测（临时密钥，不影响 examples/keys）
python tests/test_manifest.py
# -> tests OK
```

## 注意事项

- **私钥不入库**：`keys/` 与 `examples/keys/` 已在仓库 `.gitignore`；生产私钥只放 CI Secret 或离线保管。因此别人 clone 后无法复现 `manifest.signed.json`，需用自己的密钥重签（或用 CI 产物）。
- 正式发行时：清单由 CI 生成 → 用生产密钥签名 → 校验 `min-sequence` → 发布到 `manifests/<channel>/manifest.json`（见 `06_方案设计/05_工程与发布/安装布局.md` 第 6 节）。
- `catalog.models`、`service.*` 等组件如加入镜像，请放组件级 `mirrors[]`，**每个镜像内容必须返回同一 sha256**。
