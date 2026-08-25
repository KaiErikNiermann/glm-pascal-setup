#!/usr/bin/env python3
"""Liveness check for every external artifact this guide depends on.

Run by CI monthly. The point is that the guide fails loudly the day an upstream
asset disappears, instead of quietly wasting a reader's afternoon.

Deliberately stdlib-only: this runs in CI where adding dependencies is friction,
and the whole job is a handful of HTTP requests.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any, Final, Literal

TIMEOUT: Final[int] = 30
UA: Final[str] = "glm-pascal-setup-asset-check/1.0 (+https://github.com)"


class Status(StrEnum):
    OK = "ok"
    GONE = "gone"
    ERROR = "error"


@dataclass(frozen=True, slots=True)
class Result:
    name: str
    status: Status
    detail: str


def _get(url: str, headers: dict[str, str] | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""


def check_hf_file(a: dict[str, Any]) -> Result:
    """The repo must exist AND still contain the exact filename we tell people to fetch."""
    repo, want = a["repo"], a["file"]
    code, body = _get(f"https://huggingface.co/api/models/{repo}")
    if code != 200:
        return Result(a["name"], Status.GONE, f"repo API returned {code}")
    files = {s["rfilename"] for s in json.loads(body).get("siblings", [])}
    if want not in files:
        near = sorted(f for f in files if f.endswith(".gguf"))[:4]
        return Result(a["name"], Status.GONE, f"'{want}' no longer in repo; .gguf present: {near}")
    return Result(a["name"], Status.OK, f"{repo}/{want}")


def check_github_release(a: dict[str, Any]) -> Result:
    repo, tag = a["repo"], a["tag"]
    code, _ = _get(f"https://api.github.com/repos/{repo}/releases/tags/{tag}")
    if code == 200:
        return Result(a["name"], Status.OK, f"{repo}@{tag}")
    if code == 404:
        return Result(a["name"], Status.GONE, f"release tag {tag} not found in {repo}")
    return Result(a["name"], Status.ERROR, f"GitHub API returned {code} (rate limit?)")


def check_docker_image(a: dict[str, Any]) -> Result:
    """Docker Hub needs an anonymous pull token before the manifest is readable."""
    image, tag = a["image"], a["tag"]
    code, body = _get(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{image}:pull"
    )
    if code != 200:
        return Result(a["name"], Status.ERROR, f"token endpoint returned {code}")
    token = json.loads(body).get("token", "")
    accept = (
        "application/vnd.docker.distribution.manifest.list.v2+json,"
        "application/vnd.oci.image.index.v1+json,"
        "application/vnd.docker.distribution.manifest.v2+json"
    )
    code, _ = _get(
        f"https://registry-1.docker.io/v2/{image}/manifests/{tag}",
        {"Authorization": f"Bearer {token}", "Accept": accept},
    )
    if code == 200:
        return Result(a["name"], Status.OK, f"{image}:{tag}")
    if code == 404:
        return Result(a["name"], Status.GONE, f"{image}:{tag} no longer published")
    return Result(a["name"], Status.ERROR, f"registry returned {code}")


def check_aur_package(a: dict[str, Any]) -> Result:
    pkg = a["package"]
    code, body = _get(f"https://aur.archlinux.org/rpc/v5/info?arg[]={pkg}")
    if code != 200:
        return Result(a["name"], Status.ERROR, f"AUR RPC returned {code}")
    payload = json.loads(body)
    if payload.get("resultcount", 0) < 1:
        return Result(a["name"], Status.GONE, f"AUR package '{pkg}' no longer exists")
    ver = payload["results"][0].get("Version", "?")
    return Result(a["name"], Status.OK, f"{pkg} {ver}")


CHECKS: Final[dict[str, Any]] = {
    "hf_file": check_hf_file,
    "github_release": check_github_release,
    "docker_image": check_docker_image,
    "aur_package": check_aur_package,
}


def run(manifest: Path, strict: bool) -> Literal[0, 1]:
    assets = json.loads(manifest.read_text())["assets"]
    results: list[Result] = []
    for a in assets:
        check = CHECKS.get(a["kind"])
        if check is None:
            results.append(Result(a["name"], Status.ERROR, f"unknown kind '{a['kind']}'"))
            continue
        try:
            results.append(check(a))
        # A single check crashing must not hide the results of all the others.
        except Exception as e:
            results.append(Result(a["name"], Status.ERROR, f"{type(e).__name__}: {e}"))

    mark = {Status.OK: "PASS", Status.GONE: "GONE", Status.ERROR: "WARN"}
    width = max(len(r.name) for r in results)
    for r in results:
        print(f"{mark[r.status]}  {r.name:<{width}}  {r.detail}")

    gone = [r for r in results if r.status is Status.GONE]
    errs = [r for r in results if r.status is Status.ERROR]
    print()
    if gone:
        print(f"{len(gone)} asset(s) are GONE. The guide is now partly unfollowable.")
        print("Update the guide or mark it deprecated.")
        return 1
    if errs:
        # Transient network/rate-limit noise should not page anyone at 3am, but in
        # strict mode (manual runs) we want to hear about it.
        print(f"{len(errs)} check(s) could not complete (network or rate limit).")
        return 1 if strict else 0
    print("All assets reachable.")
    return 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    default_manifest = Path(__file__).resolve().parent.parent / "assets.json"
    p.add_argument("--manifest", type=Path, default=default_manifest)
    p.add_argument(
        "--strict", action="store_true", help="treat unreachable-but-not-gone as failure"
    )
    args = p.parse_args()
    sys.exit(run(args.manifest, args.strict))


if __name__ == "__main__":
    main()
