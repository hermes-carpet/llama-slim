#!/usr/bin/env python3
"""Fix the auto-rebuild.yml by:
1. Restoring the broken 'Advance upstream-sha' step indentation
2. Appending a lightweight 'prune-only' job at the end

Run from any directory: python3 fix-workflow.py /path/to/auto-rebuild.yml
"""
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Step 1: Fix the broken 'Advance upstream-sha' section
old = (
    '          echo "published as latest / v${RELEASE_VERSION}"\n'
    '\n'
    '          - name: Advance upstream-sha + release-version + commit\n'
    '          if: success()\n'
)
assert old in content, "broken block not found -- already fixed?"
content = content.replace(old, (
    '          echo "published as latest / v${RELEASE_VERSION}"\n'
    '\n'
    '      - name: Advance upstream-sha + release-version + commit\n'
    '        if: success()\n'
    '        run: |\n'
    '          set -euo pipefail\n'
    '          echo "$UPSTREAM_SHA" > upstream-sha\n'
    '          echo "$RELEASE_VERSION" > release-version\n'
    '          git config user.name  "hermes-carpet"\n'
    '          git config user.email "hermes-carpet@users.noreply.github.com"\n'
    '          git add upstream-sha release-version\n'
    '          if git diff --cached --quiet; then\n'
    '            echo "state already current (no new commit); nothing to advance"\n'
    '          else\n'
    '            git commit -m "auto-rebuild: publish v${RELEASE_VERSION} for upstream $UPSTREAM_SHA"\n'
    '            # Rebase over any commits that landed during the ~25-min build\n'
    '            # (e.g. Dependabot / manual pushes) before pushing.\n'
    '            git pull --rebase origin main\n'
    '            git push\n'
    '            echo "pushed new upstream-sha + release-version"\n'
    '          fi\n'
))

# Step 2: Append the prune-only job (uses ${{ github.token }})
tpl_token = "${{ github.token }}"
appendix = (
    '\n'
    '  # Standalone prune pass -- runs in two cases:\n'
    '  #   1. force_prune dispatch input = true  (no build, no publish, just prune)\n'
    '  #   2. a publish just happened            (re-run prune on the same SHA)\n'
    '  # Keeps the tag registry clean without needing a full build every time.\n'
    '  prune-only:\n'
    '    runs-on: ubuntu-24.04\n'
    '    timeout-minutes: 10\n'
    '    needs: [check-upstream]\n'
    "    if: inputs.force_prune == 'true' || needs.check-upstream.outputs.changed == 'true'\n"
    '    steps:\n'
    '      - uses: actions/checkout@v6\n'
    '\n'
    '      - name: Prune stray GHCR tags via REST Packages API\n'
    '        env:\n'
    f'          GH_TOKEN: {tpl_token}\n'
    '        run: |\n'
    '          set -euo pipefail\n'
    '          python3 scripts/prune-ghcr-tags.py || true\n'
    '          echo "prune-only complete"\n'
)
content = content.rstrip("\n") + appendix

with open(path, 'w') as f:
    f.write(content)
print("OK:", len(content), "bytes")
