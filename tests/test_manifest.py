import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "manifest.py")


def run(*args, expect=0):
    p = subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True)
    assert p.returncode == expect, (p.returncode, p.stdout, p.stderr)
    return p


def test_sign_verify_and_tamper(tmp_path):
    keys = tmp_path / "keys"
    run("keygen", "--out", str(keys))
    manifest = tmp_path / "manifest.json"
    run("init", "--out", str(manifest))
    signed = tmp_path / "signed.json"
    run("sign", str(manifest), "--key", str(keys / "private.pem"), "--out", str(signed))
    run("verify", str(signed), "--pub", str(keys / "public.pem"), "--min-sequence", "1")

    obj = json.loads(signed.read_text(encoding="utf-8"))
    obj["components"][0]["version"] = "9.9.9"
    tampered = tmp_path / "tampered.json"
    tampered.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    run("verify", str(tampered), "--pub", str(keys / "public.pem"), expect=1)

    obj2 = json.loads(manifest.read_text(encoding="utf-8"))
    obj2["sequence"] = 0
    lowseq_src = tmp_path / "lowseq_src.json"
    lowseq_src.write_text(json.dumps(obj2, ensure_ascii=False), encoding="utf-8")
    lowseq = tmp_path / "lowseq.json"
    run("sign", str(lowseq_src), "--key", str(keys / "private.pem"), "--out", str(lowseq))
    run("verify", str(lowseq), "--pub", str(keys / "public.pem"), "--min-sequence", "3", expect=5)


if __name__ == "__main__":
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as d:
        test_sign_verify_and_tamper(Path(d))
    print("tests OK")