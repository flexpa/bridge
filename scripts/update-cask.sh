#!/usr/bin/env bash
# Publishes a new version of the Homebrew cask to flexpa/homebrew-tap.
#
#   scripts/update-cask.sh <version> <dmg-sha256>
#
# Creates the tap repository on first run. Needs a token with repo scope on the
# tap in GH_TOKEN (CI uses the HOMEBREW_TAP_TOKEN secret; locally `gh auth` is enough).
set -euo pipefail

VERSION="${1:?usage: update-cask.sh <version> <dmg-sha256>}"
SHA256="${2:?usage: update-cask.sh <version> <dmg-sha256>}"
TAP="${HOMEBREW_TAP_REPO:-flexpa/homebrew-tap}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The tap is created once, by hand (see docs/RELEASING.md). CI never creates repositories:
# that would force the release token to carry far broader scope than updating one file needs.
if ! gh repo view "$TAP" > /dev/null 2>&1; then
  echo "  $TAP does not exist or is unreachable. Create it once:" >&2
  echo "    gh repo create $TAP --public --description 'Homebrew tap for Flexpa'" >&2
  exit 1
fi

echo "updating the cask to $VERSION"
# git itself has no credentials in CI; gh holds the token, so let it configure the helper.
gh auth setup-git 2>/dev/null || true
gh repo clone "$TAP" "$WORK/tap" -- -q
mkdir -p "$WORK/tap/Casks"
# Substitute in python rather than sed: a version containing & or / corrupts a sed replacement.
VERSION="$VERSION" SHA256="$SHA256" python3 -c '
import os, sys
t = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(t.replace("__VERSION__", os.environ["VERSION"]).replace("__SHA256__", os.environ["SHA256"]))
' "$ROOT/Packaging/homebrew/flexpa-health-bridge.rb" "$WORK/tap/Casks/flexpa-health-bridge.rb"

cd "$WORK/tap"
# Stage first, then compare against the index. Plain `git diff` ignores untracked files, so on a
# fresh tap the new cask looked like "no change" and was never published.
git add Casks/flexpa-health-bridge.rb
if git diff --cached --quiet; then
  echo "  cask already at $VERSION, nothing to push"
  exit 0
fi
git -c user.name="flexpa-bot" -c user.email="engineering@flexpa.com" \
  commit -qm "flexpa-health-bridge $VERSION"
git push -q origin HEAD
echo "✓ $TAP now serves flexpa-health-bridge $VERSION"
