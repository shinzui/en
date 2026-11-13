#!/usr/bin/env bash
# Build the reference ("baseline") en-server binary from a recorded commit.
#
#   en-server/loadbench/build-baseline.sh <commit>
#
# Checks the commit out into a temporary git worktree under .dev/loadbench/, builds
# en-server there, copies the binary to .dev/loadbench/en-server-baseline and records the
# full commit hash in .dev/loadbench/baseline.sha. The worktree is removed afterwards even
# when the build fails, so the script is safe to re-run. The build directory is kept, so
# a rebuild only recompiles what changed.
#
# Run inside the development shell (`nix develop`), from anywhere in the repository.
# See docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <commit>" >&2
  exit 2
fi

root="$(git rev-parse --show-toplevel)"
out="$root/.dev/loadbench"
sha="$(git -C "$root" rev-parse --verify "$1^{commit}")"
worktree="$out/worktree"
builddir="$out/dist-baseline"

remove_worktree() {
  git -C "$root" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
  git -C "$root" worktree prune
}

mkdir -p "$out"
remove_worktree
trap remove_worktree EXIT

git -C "$root" worktree add --detach "$worktree" "$sha" >&2
(
  cd "$worktree"
  cabal build -v1 --builddir="$builddir" en-server:exe:en-server >&2
  binary="$(cabal list-bin -v0 --builddir="$builddir" en-server:exe:en-server)"
  cp "$binary" "$out/en-server-baseline.tmp"
)
mv "$out/en-server-baseline.tmp" "$out/en-server-baseline"
echo "$sha" >"$out/baseline.sha"
echo "baseline en-server built from $sha: $out/en-server-baseline"
