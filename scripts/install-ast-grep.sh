#!/usr/bin/env bash
# Prints the path of the ast-grep the detector's rules are written for,
# installing it first if need be. The version is pinned here; bump it, and the
# checksums with it, in its own pull request, since the rules' matches can
# change with the grammar.
#
# Looks, in order, at:
#   1. $AST_GREP, which must be the pinned version;
#   2. `ast-grep` on PATH, used only if it is the pinned version;
#   3. the cache: $WEAKENED_CHECKS_CACHE, else $RUNNER_TOOL_CACHE/weakened-checks
#      on a GitHub runner, else ${XDG_CACHE_HOME:-~/.cache}/weakened-checks;
#      downloaded there from the ast-grep release, checksum verified, if absent.
#
# Requires: bash, curl, unzip, and sha256sum or shasum.
set -euo pipefail

version=0.45.3
# SHA-256 of each release zip, from the release's asset digests. Update them
# with the version.
sha256() {
  case $1 in
    x86_64-unknown-linux-gnu) echo f8ac830881339d1edee6b2652f54798c0f4da5a827f2db38a08ee31117783ce8 ;;
    aarch64-unknown-linux-gnu) echo b39cfbc58da4b869a88b8a4bc57bd5deb0d24541e704cf7c257da7b53ec81c8f ;;
    x86_64-apple-darwin) echo b2ffd26f42810340326a9e8a084bdc3647a8795c1a3f21fc06bd7bef3c7c5b2c ;;
    aarch64-apple-darwin) echo 6d2279dea5bea2ad79c66ea93f5fe54ba926e398a8a26de76c56db68fe59eac6 ;;
    *) return 1 ;;
  esac
}

die() {
  echo "install-ast-grep: $*" >&2
  exit 2
}
is_pinned() { [[ $("$1" --version 2>/dev/null) == "ast-grep $version" ]]; }

if [[ $# -gt 0 ]]; then
  case $1 in
    --version) echo "$version"; exit 0 ;;
    *) die "usage: install-ast-grep.sh [--version]" ;;
  esac
fi

if [[ -n ${AST_GREP:-} ]]; then
  is_pinned "$AST_GREP" || die "AST_GREP=$AST_GREP is not ast-grep $version"
  echo "$AST_GREP"
  exit 0
fi
if found=$(command -v ast-grep) && is_pinned "$found"; then
  echo "$found"
  exit 0
fi

cache=${WEAKENED_CHECKS_CACHE:-}
if [[ -z $cache ]]; then
  if [[ -n ${RUNNER_TOOL_CACHE:-} ]]; then
    cache=$RUNNER_TOOL_CACHE/weakened-checks
  else
    cache=${XDG_CACHE_HOME:-$HOME/.cache}/weakened-checks
  fi
fi
dir=$cache/ast-grep-$version
if [[ -x $dir/ast-grep ]] && is_pinned "$dir/ast-grep"; then
  echo "$dir/ast-grep"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) target=x86_64-unknown-linux-gnu ;;
  Linux-aarch64 | Linux-arm64) target=aarch64-unknown-linux-gnu ;;
  Darwin-x86_64) target=x86_64-apple-darwin ;;
  Darwin-arm64) target=aarch64-apple-darwin ;;
  *) die "no ast-grep $version build for $(uname -s) $(uname -m); set AST_GREP" ;;
esac
want=$(sha256 "$target")
zip=app-$target.zip
mkdir -p "$cache"
tmp=$(mktemp -d "$cache/.install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
echo "install-ast-grep: downloading ast-grep $version ($target)" >&2
curl -fsSL --retry 3 -o "$tmp/$zip" \
  "https://github.com/ast-grep/ast-grep/releases/download/$version/$zip" ||
  die "download failed"
if command -v sha256sum >/dev/null; then
  got=$(sha256sum "$tmp/$zip")
else
  got=$(shasum -a 256 "$tmp/$zip")
fi
[[ ${got%% *} == "$want" ]] || die "checksum mismatch for $zip: got ${got%% *}, want $want"
mkdir "$tmp/out"
unzip -q "$tmp/$zip" ast-grep -d "$tmp/out" || die "unzip failed"
chmod +x "$tmp/out/ast-grep"
is_pinned "$tmp/out/ast-grep" || die "the downloaded binary isn't ast-grep $version"
# Another run may have installed it meanwhile; either copy is the same.
[[ -e $dir ]] || mv "$tmp/out" "$dir" 2>/dev/null || true
is_pinned "$dir/ast-grep" || die "couldn't install into $dir"
echo "$dir/ast-grep"
