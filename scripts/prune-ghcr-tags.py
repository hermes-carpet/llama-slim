#!/usr/bin/env python3
"""Prune legacy (raw-SHA / one-off) container tags from a GHCR package.

Why this exists:
  GHCR does NOT implement distribution-spec DELETE —
  ``DELETE /v2/<repo>/manifests/<tag>`` returns 405 "operation is
  unsupported" (even with a token granted `delete`, by tag or by digest).
  The supported way to delete a published image version is the GitHub
  GraphQL ``deletePackageVersion`` mutation, which requires a token with
  packages scope (CI GITHUB_TOKEN, or a user token with write:packages).

Behavior:
  Keeps versions that carry at least one tag matching:
      latest | <semver> (e.g. 0.4.0) | cuda-13.3
  Deletes every other version (40+ legacy upstream-SHA tags from the
  pre-semver era, plus one-off probe tags). Always exits 0 (best-effort);
  it must never fail the CI run.

Env:
  GITHUB_TOKEN   GitHub token with packages scope (required in CI)
  GH_PACKAGE_NAME  (default llama-server-cuda-slim)
  GH_ACCOUNT        (default hermes-carpet; user or org login)
"""
import json
import os
import re
import sys
import urllib.request
import urllib.error

GQL = "https://api.github.com/graphql"
KEEP = re.compile(r"^(latest|\d+\.\d+\.\d+|cuda-13\.3)$")
ACCT = os.environ.get("GH_ACCOUNT", "hermes-carpet")
PKG = os.environ.get("GH_PACKAGE_NAME", "llama-server-cuda-slim")


def get_token():
    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_API_TOKEN") or ""


def gql(token, query, variables=None):
    body = {"query": query}
    if variables:
        body["variables"] = variables
    req = urllib.request.Request(
        GQL,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/vnd.github+json",
            "User-Agent": "hermes-carpet-ghcr-sweep",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def find_package(token):
    """Return the package node (with versions) under user or org account."""
    for kind in ("user", "organization"):
        q = (
            "query P {"
            f'{kind}(login: "{ACCT}") {{'
            "  packages(first: 40) {"
            "    nodes {"
            "      id name packageType"
            "      versions(first: 200) { nodes { id version "
            "        tags(first: 40) { nodes { node { name } } } } }"
            "    }"
            "  }"
            "}"
            "}"
        )
        try:
            data = gql(token, q)
        except urllib.error.HTTPError as e:
            print(f"  {kind} lookup -> HTTP {e.code}; trying next")
            continue
        except Exception as e:  # noqa: BLE001
            print(f"  {kind} lookup -> {e}; trying next")
            continue
        if data.get("errors"):
            continue
        owner = data["data"].get(kind) or {}
        for p in owner.get("packages", {}).get("nodes", []):
            if p["name"] == PKG:
                return p
    return None


def main():
    token = get_token()
    if not token:
        print("WARN: no GITHUB_TOKEN; cannot prune GHCR tags (non-fatal)")
        return
    pkg = find_package(token)
    if not pkg:
        print("WARN: package not found via GraphQL (scope?). Non-fatal.")
        return

    versions = pkg["versions"]["nodes"]
    kept = [v for v in versions
            if any(KEEP.match(t["node"]["name"]) for t in v["tags"]["nodes"])]
    drop = [v for v in versions if v not in kept]
    print(f"package {PKG}: {len(versions)} versions — keep {len(kept)}, delete {len(drop)}")

    deleted = errors = 0
    for v in drop:
        tags = [t["node"]["name"][:24] for t in v["tags"]["nodes"]] or [v["version"][:24]]
        try:
            r = gql(
                token,
                "mutation Del($pid: ID!, $vid: ID!) {"
                "  deletePackageVersion(input: {packageId: $pid, versionId: $vid}) {"
                "    data version { id } } }",
                {"pid": pkg["id"], "vid": v["id"]},
            )
        except Exception as e:  # noqa: BLE001
            print(f"  ERR {tags[0]}: {e}")
            errors += 1
            continue
        if r.get("errors"):
            print(f"  ERR {tags[0]}: {json.dumps(r['errors'])[:200]}")
            errors += 1
            continue
        deleted += 1
        print(f"  deleted {tags[0]}…")
    print(f"prune done: {deleted} deleted, {errors} errors (non-fatal either way)")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print(f"WARN: prune-ghcr-tags failed: {e} (non-fatal)")
    sys.exit(0)
