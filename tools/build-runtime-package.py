"""把大型 runtime 目录打成可分卷的组件包，并生成 feed 片段/离线目录。

用法（在 ams-release 仓库）：
  python tools/build-runtime-package.py --source F:\\...\\rvc --id runtime.rvc \\
      --version 0.1.0 --target runtime/rvc/0.1.0 --out F:\\AMS-VM\\RuntimePackages --url-prefix https://example.invalid/

输出：<out>/<id>/<id>-<version>.part-001 ... + component.json + feed.json（file:// 离线 feed）。
不执行上传；上传后把 url / parts[].url 改成实际地址即可。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import zipfile
from pathlib import Path

DEFAULT_SPLIT = 1800 * 1024 * 1024


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def make_zip(source: Path, archive: Path) -> None:
    if archive.exists():
        archive.unlink()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as zf:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(source).as_posix())


def split_file(path: Path, out_dir: Path, split_size: int) -> list[Path]:
    parts: list[Path] = []
    with open(path, "rb") as f:
        index = 1
        while True:
            data = f.read(split_size)
            if not data:
                break
            part = out_dir / f"part-{index:03d}"
            part.write_bytes(data)
            parts.append(part)
            index += 1
    return parts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--url-prefix", default="file:///")
    parser.add_argument("--split-size", type=int, default=DEFAULT_SPLIT)
    args = parser.parse_args()

    source = Path(args.source).resolve()
    out_root = Path(args.out).resolve() / args.id / args.version
    if out_root.exists():
        shutil.rmtree(out_root)
    out_root.mkdir(parents=True)
    archive = out_root / f"{args.id}-{args.version}.zip"
    print("zipping", source, "->", archive)
    make_zip(source, archive)
    parts = split_file(archive, out_root, args.split_size)
    archive_sha = sha256_file(archive)
    archive_size = archive.stat().st_size
    component_parts = []
    for part in parts:
        component_parts.append({
            "url": args.url_prefix.rstrip("/") + "/" + part.name,
            "size": part.stat().st_size,
            "sha256": sha256_file(part),
        })
    component = {
        "id": args.id,
        "kind": "runtime" if args.id.startswith("runtime.") else "tool",
        "version": args.version,
        "url": component_parts[0]["url"],
        "size": archive_size,
        "sha256": archive_sha,
        "target": args.target,
        "parts": component_parts,
        "notes": f"offline split package for {args.id}; assembled archive sha256={archive_sha}",
    }
    (out_root / "component.json").write_text(json.dumps(component, ensure_ascii=False, indent=2), encoding="utf-8")
    feed = {
        "schema": "ams-update/1",
        "channel": "stable",
        "sequence": 0,
        "components": [component],
        "signature": "ed25519:OFFLINE_PLACEHOLDER",
    }
    (out_root / "feed.json").write_text(json.dumps(feed, ensure_ascii=False, indent=2), encoding="utf-8")
    print("done", len(parts), "parts", archive_size, "bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())