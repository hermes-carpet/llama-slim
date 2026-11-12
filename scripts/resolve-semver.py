#!/usr/bin/env python3
"""Resolve a display semver for a llama.cpp build SHA (shared by the image
and binary release workflows so their versioning can't drift).

Usage:
    python3 resolve-semver.py <build_sha> [recorded_sha] [recorded_version]

Prints the resolved semver (no leading v) on stdout.
  * If <build_sha> == <recorded_sha>, prints <recorded_version> (fast path).
  * Otherwise resolves the highest upstream ggml-org/llama.cpp v* semver tag
    that is an ancestor of (or identical to) <build_sha>, via the compare API.
  * Falls back to the highest known v* tag (annotated to stderr) if none is an
    ancestor, and to 0.4.0 if no tags are found at all.
Never fails hard: on any API error it prints a safe default so the run can
proceed and a human can inspect. Exit code is always 0.
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com/repos/ggml-org/llama.cpp"
UA = os.environ.get("API_UA", "hermes-carpet-llama-slim-ci")


def get(url):
    req = urllib.request.Request(
        url, headers={"Accept": "application/vnd.github+json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def ver_key(v):
    parts = v.lstrip("v").split(".")
    while len(parts) < 3:
        parts.append("0")
    try:
        return tuple(int(p) for p in parts[:3])
    except ValueError:
        return (0, 0, 0)


def main():
    sha = sys.argv[1] if len(sys.argv) > 1 else ""
    recorded_sha = sys.argv[2] if len(sys.argv) > 2 else ""
    recorded_version = sys.argv[3] if len(sys.argv) > 3 else ""

    # Fast path: this SHA was already published with a known version.
    if sha and sha == recorded_sha and recorded_version:
        print(recorded_version)
        return

    try:
        tags = []
        for page in (1, 2, 3):
            batch = get(f"{API}/tags?per_page=100&page={page}")
            if not isinstance(batch, list) or not batch:
                break
            tags.extend(batch)
        candidates = []
        for t in tags:
            name = t.get("name", "")
            if not (name.startswith("v") and name[1:2].isdigit()):
                continue
            c = t.get("commit", {})
            tc = (c.get("sha") or "") if isinstance(c, dict) else ""
            if tc:
                candidates.append((name, tc[:12]))
        if not candidates:
            print("WARN: no upstream release tags found; defaulting to 0.4.0", file=sys.stderr)
            print("0.4.0")
            return

        def ancestor(base, sha):
            try:
                d = get(f"{API}/compare/{base}...{sha}")
                return d.get("status") in ("ahead", "identical")
            except Exception:
                return False

        versions = [n for n, _ in candidates if ancestor(n, sha) or n.removeprefix("v") in sha]
        if versions:
            version = max(versions, key=lambda n: ver_key(n))[1:]
            print(f"resolved highest ancestor semver: v{version}", file=sys.stderr)
        else:
            version = candidates[0][0][1:]
            for n, _ in candidates:
                if ver_key(n) > ver_key(version):
                    version = n[1:]
            print(f"note: no release-tag ancestor; using highest known v{version}", file=sys.stderr)
        print(version)
    except Exception as e:  # noqa: BLE001
        print(f"WARN: semver resolve failed ({e}); defaulting to 0.4.0", file=sys.stderr)
        print("0.4.0")


if __name__ == "__main__":
    main()
