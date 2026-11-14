#!/usr/bin/env python3
"""확장 하나만 새 버전으로 내보냅니다 (앱 릴리스 없이).

    python3 scripts/release-extension.py <이름> [--min-kongi 2.2.3] [--publish]
    python3 scripts/release-extension.py --self-test

먼저 extensions/<이름>/kongi-extension.json 의 "version"을 올려 두세요 (필요하면 "minKongi"도).
이 스크립트가 하는 일:
  1. marketplace/catalog-v2.json: 지금까지의 최신 버전에 그 버전이 든 공개 커밋(ref)을 박아 두고 (예전 Kongi가 계속 받도록),
     새 버전을 최신(ref 없음 = main)으로 추가합니다.
  2. marketplace/catalog.json (Kongi 2.2.2 이하용, 예전 형식): 그 앱들은 버전을 고르지 못하고 늘 main을 받으므로,
     새 버전이 그 앱에서 안 돌아가면 버전을 올리지 않습니다 (설치된 것은 그대로, 새로 설치할 때는 목록에서 빼서 못 받게).
  3. --publish: 공개 저장소(kongi-public)에 extensions/와 marketplace/만 바꾼 커밋을 만들어 main에 push합니다 (태그 없음).
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEGACY_KONGI = "2.2.2"  # catalog.json만 읽는 마지막 Kongi
AUTHOR = ["-c", "user.name=eocnd36", "-c", "user.email=347174427+eocnd36@users.noreply.github.com"]


def version_tuple(text):
    try:
        return tuple(int(part) for part in text.split("."))
    except (AttributeError, ValueError):
        return None


def newer(a, b):
    """a가 b보다 새 버전인지 (Kongi의 AppUpdate.isNewer와 같은 규칙)"""
    va, vb = version_tuple(a), version_tuple(b)
    if va is None or vb is None:
        return False
    width = max(len(va), len(vb))
    return va + (0,) * (width - len(va)) > vb + (0,) * (width - len(vb))


def runs_on(min_kongi, app):
    return not min_kongi or not newer(min_kongi, app)


def plan(v2, legacy, source, manifest, previous_ref):
    """두 목록을 새 버전에 맞게 고칩니다. 바꾼 목록 두 개를 돌려줍니다."""
    version = manifest["version"]
    min_kongi = manifest.get("minKongi")
    entry = next((e for e in v2 if e["source"] == source), None)
    if entry is None:
        raise SystemExit(f"{source} isn't in catalog-v2.json yet. Add an entry (name, description, localized) first.")
    versions = entry.setdefault("versions", [{"version": entry.get("version", "0")}])
    if any(v["version"] == version for v in versions):
        raise SystemExit(f"{source} {version} is already listed. Bump \"version\" in kongi-extension.json first.")
    if not all(newer(version, v["version"]) for v in versions):
        raise SystemExit(f"{version} isn't newer than every listed version of {source}.")
    # 지금 최신(ref 없음)에 그 버전이 든 커밋을 박아 둡니다.
    for v in versions:
        if not v.get("ref"):
            v["ref"] = previous_ref
    new = {"version": version}
    if min_kongi:
        new["minKongi"] = min_kongi
    versions.append(new)
    entry["version"] = version

    # 예전 Kongi용 목록: 새 버전이 그 앱에서 돌아갈 때만 따라 올립니다.
    old = next((e for e in legacy if e["source"] == source), None)
    if runs_on(min_kongi, LEGACY_KONGI):
        if old is None:
            legacy.append({k: entry[k] for k in ("name", "description", "source", "author", "version") if k in entry})
        else:
            old["version"] = version
    elif old is not None:
        legacy.remove(old)
    return v2, legacy


def git(*args, env=None, input=None):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True, env=env, input=input).stdout.strip()


def publish(message):
    """kongi-public에 extensions/·marketplace/만 바꾼 커밋을 만들어 push (앱 소스는 건드리지 않음)"""
    git("fetch", "-q", "kongi")
    if git("rev-parse", "kongi/main") != git("rev-parse", "kongi-public"):
        raise SystemExit("kongi-public isn't the same as kongi/main. Sync it first.")
    with tempfile.TemporaryDirectory() as work:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(work, "index"))
        git("read-tree", "kongi-public", env=env)
        # 마켓플레이스 목록에 오른 확장만 올립니다 (만들고 있는·대기 중인 확장은 공개되지 않게).
        listed = [e["source"].split("/")[-1] for e in json.loads((ROOT / "marketplace/catalog-v2.json").read_text())]
        paths = ["extensions/README.md", "marketplace"] + [f"extensions/{name}" for name in listed]
        git("rm", "-r", "-q", "-f", "--cached", "--ignore-unmatch", "extensions", "marketplace", env=env)  # 임시 색인이라 강제로 빼도 안전
        git("add", *paths, env=env)
        tree = git("write-tree", env=env)
    changed = git("diff", "--name-only", "kongi-public", tree).splitlines()
    allowed = tuple(f"extensions/{name}/" for name in listed) + ("extensions/README.md", "marketplace/")
    outside = [path for path in changed if not path.startswith(allowed)]
    if outside:
        raise SystemExit(f"Refusing to publish files that aren't listed extensions or the marketplace: {outside}")
    env = dict(os.environ, GIT_AUTHOR_NAME="eocnd36", GIT_AUTHOR_EMAIL="347174427+eocnd36@users.noreply.github.com",
               GIT_COMMITTER_NAME="eocnd36", GIT_COMMITTER_EMAIL="347174427+eocnd36@users.noreply.github.com")
    commit = git("commit-tree", tree, "-p", "kongi-public", "-m", message, env=env)
    git("branch", "-f", "kongi-public", commit)
    git("push", "-q", "kongi", "kongi-public:main")
    print(f"Published {commit[:8]}: {', '.join(changed)}")


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 1
    name = argv[0]
    folder = ROOT / "extensions" / name
    manifest_path = folder / "kongi-extension.json"
    manifest = json.loads(manifest_path.read_text())
    if "--min-kongi" in argv:
        manifest["minKongi"] = argv[argv.index("--min-kongi") + 1]
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    source = f"eocnd36/Kongi/extensions/{name}"
    # 지금 공개 main에 있는 것이 '지금까지의 최신' 버전입니다.
    previous_ref = git("rev-parse", "kongi-public")
    published = json.loads(git("show", f"{previous_ref}:extensions/{name}/kongi-extension.json") or "{}")
    v2_path, legacy_path = ROOT / "marketplace/catalog-v2.json", ROOT / "marketplace/catalog.json"
    v2, legacy = plan(json.loads(v2_path.read_text()), json.loads(legacy_path.read_text()), source, manifest, previous_ref)
    latest_pinned = [v for e in v2 if e["source"] == source for v in e["versions"] if v.get("ref") == previous_ref]
    for v in latest_pinned:
        if v["version"] != published.get("version"):
            raise SystemExit(f"The public commit has {name} {published.get('version')}, but the catalog says {v['version']}.")
    v2_path.write_text(json.dumps(v2, indent=2, ensure_ascii=False) + "\n")
    legacy_path.write_text(json.dumps(legacy, indent=2, ensure_ascii=False) + "\n")
    print(f"{name} {manifest['version']} (minKongi {manifest.get('minKongi', '-')}); previous pinned to {previous_ref[:8]}")
    print("Kongi ≤ 2.2.2:", "gets this version" if runs_on(manifest.get("minKongi"), LEGACY_KONGI) else "not offered (keeps what's installed)")
    if "--publish" in argv:
        publish(f"Extension {name} {manifest['version']}\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
    else:
        print("Review the diff, then run again with --publish (or publish by hand).")
    return 0


def self_test():
    v2 = [{"name": "P", "description": "d", "source": "s", "author": "Kongi", "version": "1.1",
           "versions": [{"version": "1.1", "minKongi": "2.2.3"}]}]
    legacy = []
    # 새 Kongi가 필요한 업데이트: 예전 최신은 커밋으로 고정, 예전 앱 목록에는 안 들어감
    v2, legacy = plan(v2, legacy, "s", {"version": "1.2", "minKongi": "2.4.0"}, "abc")
    versions = v2[0]["versions"]
    assert versions == [{"version": "1.1", "minKongi": "2.2.3", "ref": "abc"}, {"version": "1.2", "minKongi": "2.4.0"}], versions
    assert v2[0]["version"] == "1.2" and legacy == []
    # 예전 앱에서도 도는 업데이트: 예전 목록 버전도 따라 올라감
    v2b = [{"name": "C", "description": "d", "source": "c", "author": "Kongi", "version": "2.1", "versions": [{"version": "2.1", "minKongi": "2.1.0"}]}]
    legacy_b = [{"name": "C", "description": "d", "source": "c", "author": "Kongi", "version": "2.1"}]
    v2b, legacy_b = plan(v2b, legacy_b, "c", {"version": "2.2", "minKongi": "2.1.0"}, "def")
    assert legacy_b[0]["version"] == "2.2" and v2b[0]["versions"][0]["ref"] == "def"
    # 예전 앱에서 안 도는 업데이트: 예전 목록에서 빠짐
    v2c, legacy_c = plan(json.loads(json.dumps(v2b)), json.loads(json.dumps(legacy_b)), "c", {"version": "3.0", "minKongi": "2.3.0"}, "ghi")
    assert legacy_c == [] and [v.get("ref") for v in v2c[0]["versions"]] == ["def", "ghi", None]
    # 같은 버전·더 낮은 버전은 거부
    for bad in ("3.0", "2.9"):
        try:
            plan(json.loads(json.dumps(v2c)), [], "c", {"version": bad}, "x")
        except SystemExit:
            pass
        else:
            raise AssertionError(f"{bad} should be refused")
    assert newer("2.10", "2.9") and not newer("2.2.2", "2.2.2") and runs_on("2.2.2", "2.2.2") and not runs_on("2.2.3", "2.2.2")
    print("self-test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
