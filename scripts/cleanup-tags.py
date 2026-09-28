#!/usr/bin/env python3
"""Delete the stray cuda-13.3 tag from GHCR using the REST Packages API.

Run from within a GH Actions job that has packages: write permission. Reads
the GITHUB_TOKEN env var which Actions auto-injects.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "hermes-carpet"
PKG = "llama-server-cuda-slim"
TAG = "cuda-13.3"


def api_get(path: str, token: str) -> tuple[int, dict]:
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "hermes-carpet-cleanup",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code} on GET {url}: {exc.read().decode()[:500]}")
        return exc.code, {}


def api_delete(path: str, token: str) -> tuple[int, dict]:
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(
        url,
        method="DELETE",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "hermes-carpet-cleanup",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()[:500]
        return exc.code, {"error": body}


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("error: GITHUB_TOKEN env var not set", file=sys.stderr)
        return 2

    print(f"target package: {REPO}/{PKG}, dropping tag: {TAG}")

    # List versions for this package
    status, data = api_get(f"/user/packages/container/{PKG}/versions?per_page=100", token)
    print(f"packages API status={status}, versions_found={len(data or [])}")
    if status != 200:
        print(f"failed to list versions: {data}")
        return 1

    targets = []
    for ver in data:
        names = [v.get("name") for v in ver.get("versions", [])]
        print(f"  version id={ver.get('id')}: {names}")
        if TAG in names:
            targets.append(ver.get("id"))

    if not targets:
        print(f"tag {TAG!r} not found (already cleaned?)")
        return 0

    for vid in targets:
        status, resp = api_delete(
            f"/user/packages/container/{PKG}/versions/{vid}", token
        )
        print(f"DELETE /versions/{vid} -> {status}: {resp}")

    # Verify
    status, data = api_get(f"/user/packages/container/{PKG}/versions?per_page=100", token)
    remaining = {v.get("name") for ver in data for v in ver.get("versions", [])}
    print(f"remaining tags after cleanup: {sorted(remaining)}")
    return 0 if TAG not in remaining else 3

if __name__ == "__main__":
    raise SystemExit(main())
