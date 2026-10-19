#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AMS 更新清单签名/校验工具（Ed25519）。

清单格式见 06_方案设计/00_总体设计与约定.md 第 11 节（ams-update/1）。
用法:
  python manifest.py keygen --out keys
  python manifest.py sign manifest.json --key keys/private.pem --out manifest.signed.json
  python manifest.py verify manifest.signed.json --pub keys/public.pem [--min-sequence 3]
"""
import argparse
import base64
import json
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

SIG_PREFIX = "ed25519:"
CHANNELS = ("stable", "beta", "dev")


def canonical_bytes(obj):
    """签名覆盖“除 signature 外的完整清单”。"""
    copy = {k: v for k, v in obj.items() if k != "signature"}
    return json.dumps(copy, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def dump_json(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def validate_manifest(obj):
    errors = []
    if obj.get("schema") != "ams-update/1":
        errors.append("schema 必须为 ams-update/1")
    if obj.get("channel") not in CHANNELS:
        errors.append("channel 必须为 stable/beta/dev 之一")
    if not isinstance(obj.get("sequence"), int) or obj["sequence"] < 0:
        errors.append("sequence 必须为非负整数")
    comps = obj.get("components")
    if not isinstance(comps, list) or not comps:
        errors.append("components 必须为非空数组")
        return errors
    seen = set()
    for i, c in enumerate(comps):
        tag = "components[%d]" % i
        if not isinstance(c, dict):
            errors.append(tag + " 必须是对象")
            continue
        cid = c.get("id")
        if not isinstance(cid, str) or not cid:
            errors.append(tag + ".id 必须为非空字符串")
        elif cid in seen:
            errors.append(tag + ".id 重复: " + cid)
        else:
            seen.add(cid)
        if c.get("kind") not in ("launcher", "kernel", "plugin", "service", "tool", "catalog"):
            errors.append(tag + ".kind 非法")
        if not isinstance(c.get("version"), str) or not c.get("version"):
            errors.append(tag + ".version 必须为非空字符串")
        if not isinstance(c.get("url"), str) or not c.get("url").startswith("https://"):
            errors.append(tag + ".url 必须为 https URL")
        sha = c.get("sha256")
        if not isinstance(sha, str) or len(sha) != 64:
            errors.append(tag + ".sha256 必须为 64 位 hex")
        if not isinstance(c.get("size"), int) or c.get("size", -1) < 0:
            errors.append(tag + ".size 必须为非负整数")
    return errors


def cmd_keygen(args):
    os.makedirs(args.out, exist_ok=True)
    priv_path = os.path.join(args.out, "private.pem")
    pub_path = os.path.join(args.out, "public.pem")
    if os.path.exists(priv_path) and not args.force:
        print("已存在私钥，拒绝覆盖（--force 可覆盖）：" + priv_path, file=sys.stderr)
        return 2
    priv = Ed25519PrivateKey.generate()
    with open(priv_path, "wb") as f:
        f.write(priv.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ))
    with open(pub_path, "wb") as f:
        f.write(priv.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        ))
    print("private ->", priv_path)
    print("public  ->", pub_path)
    print("提示：私钥只放 CI Secret 或离线保管；public.pem 内置启动器。")
    return 0


def cmd_sign(args):
    obj = load_json(args.manifest)
    errors = validate_manifest(obj)
    if errors:
        print("清单校验失败：", file=sys.stderr)
        for e in errors:
            print(" - " + e, file=sys.stderr)
        return 3
    with open(args.key, "rb") as f:
        priv = serialization.load_pem_private_key(f.read(), password=None)
    if not isinstance(priv, Ed25519PrivateKey):
        print("不是 Ed25519 私钥", file=sys.stderr)
        return 4
    sig = priv.sign(canonical_bytes(obj))
    out = dict(obj)
    out["signature"] = SIG_PREFIX + base64.b64encode(sig).decode("ascii")
    dump_json(args.out or (args.manifest + ".signed.json"), out)
    print("signed ->", args.out or (args.manifest + ".signed.json"))
    return 0


def cmd_verify(args):
    obj = load_json(args.manifest)
    sig_text = obj.get("signature")
    if not isinstance(sig_text, str) or not sig_text.startswith(SIG_PREFIX):
        print("缺少或非法 signature", file=sys.stderr)
        return 2
    try:
        sig = base64.b64decode(sig_text[len(SIG_PREFIX):], validate=True)
    except Exception as e:
        print("signature base64 非法: %s" % e, file=sys.stderr)
        return 2
    with open(args.pub, "rb") as f:
        pub = serialization.load_pem_public_key(f.read())
    if not isinstance(pub, Ed25519PublicKey):
        print("不是 Ed25519 公钥", file=sys.stderr)
        return 4
    try:
        pub.verify(sig, canonical_bytes(obj))
    except Exception:
        print("签名校验失败（清单被篡改或密钥不匹配）", file=sys.stderr)
        return 1
    errors = validate_manifest(obj)
    if errors:
        print("签名有效但清单校验失败：", file=sys.stderr)
        for e in errors:
            print(" - " + e, file=sys.stderr)
        return 3
    if args.min_sequence is not None and obj.get("sequence", -1) < args.min_sequence:
        print("sequence %s 小于最低要求 %s" % (obj.get("sequence"), args.min_sequence), file=sys.stderr)
        return 5
    print("OK: signature valid, schema ok, sequence=%s, components=%d" % (obj.get("sequence"), len(obj.get("components", []))))
    return 0


def cmd_init(args):
    example = {
        "schema": "ams-update/1",
        "channel": args.channel,
        "generated_at": "2026-10-19T21:00:00+08:00",
        "sequence": 1,
        "components": [
            {
                "id": "plugin.ams.music.trainer",
                "kind": "plugin",
                "version": "0.1.0",
                "url": "https://github.com/yan-mc/ams-release/releases/download/v0.1.0/trainer-0.1.0.tgz",
                "size": 12345,
                "sha256": "0" * 64,
                "requires": {"kernel": ">=0.2.1-rc.2 <0.3.0"},
                "notes": "示例清单，正式发布前替换"
            }
        ],
    }
    dump_json(args.out, example)
    print("example ->", args.out)
    return 0


def main():
    ap = argparse.ArgumentParser(description="AMS update manifest signer/verifier (ed25519)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    k = sub.add_parser("keygen", help="生成 Ed25519 密钥对")
    k.add_argument("--out", default="keys")
    k.add_argument("--force", action="store_true")
    k.set_defaults(func=cmd_keygen)

    s = sub.add_parser("sign", help="对清单签名")
    s.add_argument("manifest")
    s.add_argument("--key", required=True)
    s.add_argument("--out", default=None)
    s.set_defaults(func=cmd_sign)

    v = sub.add_parser("verify", help="校验清单签名与 schema")
    v.add_argument("manifest")
    v.add_argument("--pub", required=True)
    v.add_argument("--min-sequence", type=int, default=None)
    v.set_defaults(func=cmd_verify)

    i = sub.add_parser("init", help="生成示例清单")
    i.add_argument("--out", default="examples/manifest.json")
    i.add_argument("--channel", default="stable")
    i.set_defaults(func=cmd_init)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
