#!/usr/bin/env python3
"""Prune legacy (raw-SHA / one-off) container versions/tags from a GHCR package.

Approach (per GitHub community discussion 26267 + airtower-luna/ghcr-prune.py):
GHCR does NOT implement distribution-spec DELETE
(``DELETE https://ghcr.io/v2/<repo>/manifests/<tag>`` -> 405 "operation is
unsupported" in every auth mode), and the GitHub GraphQL ``PackageVersion``
type carries no tag-list field. Tag deletion is done through the
GitHub REST Packages API:

    GET    https://api.github.com/user/packages/container/<image>/versions
           -> each version has metadata.container.tags[]
    DELETE https://api.github.com/user/packages/container/<image>/versions/<id>

Requires a token with packages scope (CI GITHUB_TOKEN works via the
workflow ``permissions:`` block; a local token needs read:packages /
write:packages).

Behavior:
  Keeps versions carrying at least one tag matching:
      latest | <semver> (e.g. 0.4.0) | cuda-13.3
  Deletes every other version (40+ legacy upstream-SHA tags from the
  pre-semver era, plus one-off probe tags).

Always exits 0 (best-effort): it runs after a successful push and must
never fail the CI run.

Env:
  GITHUB_TOKEN | GH_API_TOKEN   GitHub token with packages scope
  GH_PACKAGE_NAME  (default llama-server-cuda-slim)
  GH_ACCOUNT       (default hermes-carpet; unused for this endpoint --
                   /user/ is resolved via the token -- but kept for logs)
  PRUNE_DRY_RUN=1      list only, no deletes
  PRUNE_MAX_DELETES=N  safety cap (default 200)
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
KEEP = re.compile(r"^(latest|\d+\.\d+\.\d+|cuda-13\.3)$")
PKG = os.environ.get("GH_PACKAGE_NAME", "llama-server-cuda-slim")
MAX_DELETES = int(os.environ.get("PRUNE_MAX_DELETES", "200"))
DRY_RUN = os.environ.get("PRUNE_DRY_RUN") == "1"


def get_token():
    # GITHUB_TOKEN first: in this workflow the base env also injects
    # GH_API_TOKEN (a fine-grained token WITHOUT packages scope), which
    # would shadow the repo token that HAS packages:write.
    return (
        os.environ.get("GITHUB_TOKEN")
        or os.environ.get("GH_API_TOKEN")
        or ""
    )


def api(token, method, path):
    req = urllib.request.Request(
        f"{API}{path}",
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "hermes-carpet-ghcr-sweep",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read().decode()
        return (r.status, json.loads(body) if body else None)


def main():
    token = get_token()
    if not token:
        print("WARN: no GITHUB_TOKEN; skipping GHCR tag prune (non-fatal)")
        return

    # Paginate the container versions (max 100 per page).
    versions = []
    page = 1
    while True:
        status, data = api(
            token, "GET",
            f"/user/packages/container/{PKG}/versions?per_page=100&page={page}",
        )
        if status != 200 or not data:
            print(f"WARN: versions list HTTP {status}; aborting prune (non-fatal)")
            return
        versions.extend(data)
        if len(data) < 100:
            break
        page += 1

    kept, drop = [], []
    for v in versions:
        tags = (v.get("metadata", {}).get("container", {}) or {}).get("tags") or []
        (kept if any(KEEP.match(t) for t in tags) else drop).append((v, tags))

    print(
        f"package {PKG}: {len(versions)} versions -- keep {len(kept)} "
        f"({', '.join(t for _, t in kept and [(v, t) for (v, t) in kept]) if kept else 'none'}), "
        f"delete {len(drop)}"
    )
    if DRY_RUN:
        for v, tags in drop:
            print(f"  dry-run would delete: {tags or v['name']} (id={v['id']})")
        print("dry-run: no deletes performed")
        return

    deleted = errors = 0
    for v, tags in drop:
        if deleted >= MAX_DELETES:
            print(f"  reached max deletions cap ({MAX_DELETES}); stopping")
            break
        label = ", ".join(tags) if tags else v["name"]
        try:
            status, _ = api(
                token, "DELETE",
                f"/user/packages/container/{PKG}/versions/{v['id']}",
            )
        except urllib.error.HTTPError as e:
            print(f"  ERR {label}: HTTP {e.code}")
            errors += 1
            continue
        except Exception as e:  # noqa: BLE001
            print(f"  ERR {label}: {e}")
            errors += 1
            continue
        if status == 204:
            deleted += 1
            print(f"  deleted {label} (id={v['id']})")
        else:
            print(f"  ERR {label}: DELETE -> {status}")
            errors += 1

    print(f"prune done: {deleted} deleted, {errors} errors (non-fatal either way)")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print(f"WARN: prune-ghcr-tags failed: {e} (non-fatal)")
    sys.exit(0)
