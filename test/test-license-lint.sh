#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/license-lint/license-lint.sh
# Run: bash test/test-license-lint.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/license-lint/license-lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A deterministic stand-in for npm. It models the parts of the CLI the lint
# action relies on: only `pack` is accepted, unknown flags are rejected, and
# --json emits JSON on stdout and nothing else. .packlist or .packlist-auto
# supplies the file list; .packfail, .packnonjson and .packwarn exercise the
# failure and warning paths.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npm" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "pack" ]]; then
  echo "npm error: only pack is supported (got: ${1:-})" >&2
  exit 1
fi
shift
json=0
for arg in "$@"; do
  case "$arg" in
    --dry-run | --ignore-scripts) ;;
    --json) json=1 ;;
    *)
      echo "npm error: unknown option: $arg" >&2
      exit 1
      ;;
  esac
done
if [[ "$json" -ne 1 ]]; then
  printf 'app-1.0.0.tgz\n'
  exit 0
fi
# Record the contents npm is asked to pack. Tests set FAKE_NPM_RECORD and
# FAKE_NPM_SOURCE; only the staged temporary package (cwd != source) is
# recorded, so the assertion is about what the lint action copied.
if [[ -n "${FAKE_NPM_RECORD:-}" && "$PWD" != "${FAKE_NPM_SOURCE:-}" ]]; then
  find . -mindepth 1 -print >>"$FAKE_NPM_RECORD"
fi
if [[ -f .packfail ]]; then
  cat .packfail >&2
  exit 1
fi
if [[ -f .packnonjson ]]; then
  printf 'npm notice this is not json\n'
  exit 0
fi
[[ -f .packwarn ]] && cat .packwarn >&2
json_out='[{"files":['
first=1
add_path() {
  [[ -n "$1" ]] || return 0
  [[ $first -eq 1 ]] || json_out+=','
  first=0
  json_out+="{\"path\":\"$1\"}"
}
# The staged temp package does not copy the fake's control files. Fall back to
# the source package's model of npm's file list, which still describes the
# project after the license is staged.
control=.
if [[ ! -f .packlist && ! -f .packlist-auto && -n "${FAKE_NPM_SOURCE:-}" ]]; then
  control="$FAKE_NPM_SOURCE"
fi
if [[ -f "$control/.packlist" ]]; then
  while IFS= read -r path; do add_path "$path"; done < "$control/.packlist"
elif [[ -f "$control/.packlist-auto" ]]; then
  while IFS= read -r -d '' path; do
    path=${path#./}
    [[ "$path" == .* ]] && continue
    [[ -f "$path" ]] || continue
    add_path "$path"
  done < <(find . -mindepth 1 -maxdepth 1 -print0)
else
  echo "npm error: no .packlist or .packlist-auto" >&2
  exit 1
fi
json_out+=']}]'
printf '%s\n' "$json_out"
FAKE
chmod +x "$WORK/bin/npm"

# run_lint <workdir> [npm-dir] [license-file] [license] [platforms-dir] [npm-mode]
run_lint() {
  local dir="$1" npm_dir="${2:-npm}" license_file="${3:-}" license="${4:-}"
  local platforms_dir="${5:-platforms}" npm_mode="${6:-auto}"
  OUT="$dir/output"
  : > "$OUT"
  local source_dir
  source_dir=$(cd "$dir/$npm_dir" 2>/dev/null && pwd) || source_dir="$dir/$npm_dir"
  (
    cd "$dir" || exit 1
    PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$OUT" FAKE_NPM_SOURCE="$source_dir" \
      bash "$SCRIPT" "$npm_dir" "$license_file" "$license" "$platforms_dir" "$npm_mode"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
}

# run_lint_with_path <workdir> <path> [npm-dir] [license-file] [license] [platforms-dir] [npm-mode]
# Used to prove behavior when npm is absent: PATH contains the script's
# dependencies but deliberately not npm.
run_lint_with_path() {
  local dir="$1" path="$2"
  shift 2
  local npm_dir="${1:-npm}" license_file="${2:-}" license="${3:-}"
  local platforms_dir="${4:-platforms}" npm_mode="${5:-auto}"
  OUT="$dir/output"
  : > "$OUT"
  (
    cd "$dir" || exit 1
    PATH="$path" GITHUB_OUTPUT="$OUT" /bin/bash "$SCRIPT" \
      "$npm_dir" "$license_file" "$license" "$platforms_dir" "$npm_mode"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
}

# make_path_without_npm <dir>
make_path_without_npm() {
  local dir="$1" cmd path
  mkdir -p "$dir"
  for cmd in bash cat cp dirname basename env find grep install jq mktemp \
    readlink rm sort stat tar tr; do
    path=$(type -P "$cmd" 2>/dev/null) || continue
    ln -sf "$path" "$dir/$cmd"
  done
}

new_case() {
  init_case "$WORK" "$1"
  mkdir -p "$DIR/npm"
  printf 'MIT License\n' > "$DIR/LICENSE"
  printf '{"name":"@scope/app","version":"1.0.0","license":"MIT"}\n' > "$DIR/npm/package.json"
  printf 'LICENSE\npackage.json\n' > "$DIR/npm/.packlist"
}

new_platform() {
  local name="$1"
  mkdir -p "$DIR/platforms/$name"
  printf '{"name":"@scope/app-linux-x64","version":"1.0.0","license":"MIT"}\n' \
    > "$DIR/platforms/$name/package.json"
  printf 'LICENSE\npackage.json\napp\n' > "$DIR/platforms/$name/.packlist"
}

# 1. clean package and platform package pass
new_case passes
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] &&
  grep -qx 'license=MIT' "$OUT" &&
  grep -qx 'license-file=LICENSE' "$OUT" &&
  grep -qx 'platform-packages=1' "$OUT"; then
  pass
else
  fail "clean layout should pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 2. missing license file fails
new_case missing-license
rm "$DIR/LICENSE"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'No license file found' "$DIR/stderr"; then
  pass
else
  fail "missing license file must fail (status=$STATUS)"
fi

# 3. empty license file fails with an actionable message
new_case empty-license
: > "$DIR/LICENSE"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'License file is empty' "$DIR/stderr"; then
  pass
else
  fail "empty license file must fail naming the empty file (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 4. ambiguous license files fail
new_case ambiguous
printf 'Apache License\n' > "$DIR/COPYING"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'Multiple license files found' "$DIR/stderr"; then
  pass
else
  fail "ambiguous license files must fail (status=$STATUS)"
fi

# 5. manifest without a license fails when there is no root fallback
new_case no-manifest-license
printf '{"name":"@scope/app","version":"1.0.0"}\n' > "$DIR/npm/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'no SPDX license found' "$DIR/stderr"; then
  pass
else
  fail "manifest without license must fail (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 6. explicit license that disagrees with the manifest fails
new_case license-mismatch
run_lint "$DIR" npm "" Apache-2.0
if [[ $STATUS -ne 0 ]] && grep -q 'does not match' "$DIR/stderr"; then
  pass
else
  fail "explicit/manifest license mismatch must fail (status=$STATUS)"
fi

# 7. invalid SPDX expression fails
new_case invalid-spdx
printf '{"name":"@scope/app","version":"1.0.0","license":"MIT OR (:"}\n' > "$DIR/npm/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'not a valid SPDX expression' "$DIR/stderr"; then
  pass
else
  fail "invalid SPDX expression must fail (status=$STATUS)"
fi

# 8. license missing from the main tarball fails
new_case main-packlist
printf 'package.json\n' > "$DIR/npm/.packlist"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'main package tarball would not include LICENSE' "$DIR/stderr"; then
  pass
else
  fail "license missing from main packlist must fail (status=$STATUS)"
fi

# 9. platform package without the license file fails
new_case platform-missing
new_platform app-linux-x64
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'does not contain LICENSE' "$DIR/stderr"; then
  pass
else
  fail "platform package without license must fail (status=$STATUS)"
fi

# 10. platform license not in its packlist fails
new_case platform-packlist
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
printf 'package.json\napp\n' > "$DIR/platforms/app-linux-x64/.packlist"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'tarball would not include LICENSE' "$DIR/stderr"; then
  pass
else
  fail "platform license outside its packlist must fail (status=$STATUS)"
fi

# 11. symlinked platform license fails
new_case platform-symlink
new_platform app-linux-x64
ln -s "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'is a symlink' "$DIR/stderr"; then
  pass
else
  fail "symlinked platform license must fail (status=$STATUS)"
fi

# 12. platform package publishing a different license fails
new_case platform-license-mismatch
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
printf '{"name":"@scope/app-linux-x64","version":"1.0.0","license":"Apache-2.0"}\n' \
  > "$DIR/platforms/app-linux-x64/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'publishes' "$DIR/stderr"; then
  pass
else
  fail "platform license mismatch must fail (status=$STATUS)"
fi

# 13. absent platforms directory is skipped, not an error
new_case no-platforms
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'platform-packages=0' "$OUT"; then
  pass
else
  fail "absent platforms dir should pass with zero packages (status=$STATUS)"
fi

# 14. custom license-file and npm-dir are honored
new_case custom-paths
mkdir -p "$DIR/pkg" "$DIR/legal"
printf 'Apache License\n' > "$DIR/legal/COPYING.txt"
printf '{"name":"@scope/app","version":"1.0.0","license":"Apache-2.0"}\n' > "$DIR/pkg/package.json"
printf 'COPYING.txt\npackage.json\n' > "$DIR/pkg/.packlist"
run_lint "$DIR" pkg legal/COPYING.txt "" platforms
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=COPYING.txt' "$OUT"; then
  pass
else
  fail "custom npm-dir and license-file should pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 15. a project without npm packages passes with a license file (auto)
new_case no-npm-auto
rm -rf "$DIR/npm"
printf '{"name":"repo","private":true}\n' > "$DIR/package.json"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] &&
  grep -qx 'license-file=LICENSE' "$OUT" &&
  grep -qx 'platform-packages=0' "$OUT" &&
  grep -q 'linting the repository license only' "$DIR/stderr"; then
  pass
else
  fail "repository without npm packages should pass in auto mode (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 16. a project without npm packages passes with no npm metadata at all
new_case no-npm-no-metadata
rm -rf "$DIR/npm" "$DIR/package.json"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -q 'no SPDX metadata found' "$DIR/stderr"; then
  pass
else
  fail "repository without npm or SPDX metadata should still lint its license file (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 17. npm-mode=required fails when there is no package manifest
new_case no-npm-required
rm -rf "$DIR/npm"
run_lint "$DIR" npm "" "" platforms required
if [[ $STATUS -ne 0 ]] && grep -q 'npm-mode=required' "$DIR/stderr"; then
  pass
else
  fail "npm-mode=required without a manifest must fail (status=$STATUS)"
fi

# 18. npm-mode=none skips npm checks even when a broken package exists
new_case npm-none
printf '{"name":"@scope/app","version":"1.0.0"}\n' > "$DIR/npm/package.json"
run_lint "$DIR" npm "" "" platforms none
if [[ $STATUS -eq 0 ]] && grep -q 'skipped npm package checks' "$DIR/stderr"; then
  pass
else
  fail "npm-mode=none should skip npm checks (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 19. an unknown npm-mode is rejected
new_case npm-mode-invalid
run_lint "$DIR" npm "" "" platforms sometimes
if [[ $STATUS -eq 2 ]] && grep -q 'npm-mode must be auto, required, or none' "$DIR/stderr"; then
  pass
else
  fail "unknown npm-mode must be rejected with exit 2 (status=$STATUS)"
fi

# 20. the canonical release layout passes: npm-dir has no license yet because
# stage-license adds it at publish time. Lint must stage a temporary copy
# before packing, or real npm would never see the license.
new_case canonical-staged-layout
rm "$DIR/npm/.packlist"
printf 'auto\n' > "$DIR/npm/.packlist-auto"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=LICENSE' "$OUT" &&
  grep -q 'main package tarball includes LICENSE' "$DIR/stderr"; then
  pass
else
  fail "canonical layout without a pre-staged license must pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 21. a differently named license in npm-dir wins, matching stage-license
new_case npm-license-wins
printf 'Apache License\n' > "$DIR/npm/LICENCE.md"
rm "$DIR/npm/.packlist"
printf 'auto\n' > "$DIR/npm/.packlist-auto"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=LICENCE.md' "$OUT" &&
  grep -q 'main package tarball includes LICENCE.md' "$DIR/stderr"; then
  pass
else
  fail "npm-dir license must win, as it does in stage-license (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 22. a failed npm pack fails the lint with npm's stderr
new_case pack-failure
printf 'npm error: EACCES permission denied\n' > "$DIR/npm/.packfail"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'npm pack failed' "$DIR/stderr" &&
  grep -q 'EACCES permission denied' "$DIR/stderr"; then
  pass
else
  fail "a failed npm pack must fail with its stderr (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 23. non-JSON npm output fails instead of being treated as an empty packlist
new_case pack-non-json
: > "$DIR/npm/.packnonjson"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'did not return JSON' "$DIR/stderr"; then
  pass
else
  fail "non-JSON npm output must fail (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 24. absolute paths in npm's file list still identify the license
new_case packlist-absolute
printf '/some/absolute/prefix/LICENSE\n' > "$DIR/npm/.packlist"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]]; then
  pass
else
  fail "absolute packlist paths must match the license (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 25. a successful pack with stderr warnings passes and surfaces the warning
new_case pack-warnings
printf 'npm warn deprecated package@1.0.0\n' > "$DIR/npm/.packwarn"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -q 'npm warn deprecated package@1.0.0' "$DIR/stderr"; then
  pass
else
  fail "npm stderr warnings on success should pass and be shown (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 26. a genuine but empty platforms directory is not an error
new_case empty-platforms-dir
mkdir -p "$DIR/platforms"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'platform-packages=0' "$OUT"; then
  pass
else
  fail "an empty platforms dir should pass with zero packages (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 27. CRLF license text is non-empty and passes
new_case crlf-license
printf 'MIT License\r\n' > "$DIR/LICENSE"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=LICENSE' "$OUT"; then
  pass
else
  fail "a CRLF license file should pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 28. mixed-case license filename is discovered
new_case mixed-case-license
rm "$DIR/LICENSE"
printf 'MIT License\n' > "$DIR/License"
printf 'License\npackage.json\n' > "$DIR/npm/.packlist"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=License' "$OUT"; then
  pass
else
  fail "mixed-case License should be discovered (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 29. a symlinked main license is dereferenced, not rejected like a platform
new_case main-license-symlink
mkdir -p "$DIR/legal"
printf 'Apache License\n' > "$DIR/legal/APACHE"
ln -s ../legal/APACHE "$DIR/npm/LICENSE"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=LICENSE' "$OUT"; then
  pass
else
  fail "a symlinked main license should be dereferenced (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 30. an explicit license that matches the manifest passes
new_case explicit-license-match
run_lint "$DIR" npm "" MIT
if [[ $STATUS -eq 0 ]] && grep -qx 'license=MIT' "$OUT"; then
  pass
else
  fail "an explicit license matching the manifest should pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 31. NOASSERTION without npm is rejected, just as in npm mode
new_case no-npm-noassertion
rm -rf "$DIR/npm"
printf '{"name":"repo","private":true,"license":"NOASSERTION"}\n' > "$DIR/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'not a publishable identifier' "$DIR/stderr"; then
  pass
else
  fail "NOASSERTION in no-npm mode must fail (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 31b. explicit-versus-root mismatch is checked without npm too
new_case no-npm-mismatch
rm -rf "$DIR/npm"
printf '{"name":"repo","private":true,"license":"MIT"}\n' > "$DIR/package.json"
run_lint "$DIR" npm "" Apache-2.0
if [[ $STATUS -ne 0 ]] && grep -q 'does not match' "$DIR/stderr"; then
  pass
else
  fail "explicit/root license mismatch must fail without npm (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 32. missing npm fails when npm packages are being linted
new_case missing-npm
make_path_without_npm "$WORK/no-npm-bin"
run_lint_with_path "$DIR" "$WORK/no-npm-bin"
if [[ $STATUS -ne 0 ]] && grep -q 'npm not found' "$DIR/stderr"; then
  pass
else
  fail "missing npm must fail when linting packages (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 33. auto mode does not silently skip when a publishable root manifest points
# at a typo'd npm-dir
new_case auto-typo-npm-dir
rm -rf "$DIR/npm"
printf '{"name":"repo","version":"1.0.0"}\n' > "$DIR/package.json"
run_lint "$DIR" npmx
if [[ $STATUS -ne 0 ]] && grep -q 'publishable' "$DIR/stderr" &&
  grep -q 'npmx/package.json' "$DIR/stderr"; then
  pass
else
  fail "auto mode with a typo'd npm-dir and a publishable root manifest must fail (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 33b. auto mode detects the canonical npm/package.json when a typo'd dir is
# passed, even when there is no root manifest to inspect.
new_case auto-typo-npm-dir-canonical
rm -f "$DIR/package.json"
run_lint "$DIR" npmx
if [[ $STATUS -ne 0 ]] && grep -q 'npm/package.json' "$DIR/stderr" &&
  grep -q 'set npm-dir' "$DIR/stderr"; then
  pass
else
  fail "auto mode with a typo'd npm-dir and a canonical npm/package.json must fail (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 33c. a genuine no-npm repository still passes even when a non-default
# npm-dir is passed: canonical detection must not invent a package.
new_case auto-no-npm-nondefault-dir
rm -rf "$DIR/npm" "$DIR/package.json"
run_lint "$DIR" npmx
if [[ $STATUS -eq 0 ]] && grep -q 'linting the repository license only' "$DIR/stderr"; then
  pass
else
  fail "a genuine no-npm repository must pass regardless of npm-dir (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 34. temp staging copies only what npm would pack, never node_modules
new_case staged-copy-skips-unpacked
rm "$DIR/npm/.packlist"
printf 'auto\n' > "$DIR/npm/.packlist-auto"
mkdir -p "$DIR/npm/node_modules/heavy"
printf 'blob\n' > "$DIR/npm/node_modules/heavy/blob"
: > "$DIR/seen"
export FAKE_NPM_RECORD="$DIR/seen"
run_lint "$DIR"
unset FAKE_NPM_RECORD
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=LICENSE' "$OUT" &&
  ! grep -q 'node_modules' "$DIR/seen"; then
  pass
else
  fail "temp staging must not copy node_modules (status=$STATUS copied=$(tr '\n' ' ' < "$DIR/seen") stderr=$(cat "$DIR/stderr"))"
fi

# 35. a malformed primary manifest is a parse error, not a missing license
new_case malformed-primary-manifest
printf '{not json\n' > "$DIR/npm/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'Could not parse npm/package.json' "$DIR/stderr" &&
  ! grep -q 'no SPDX license found' "$DIR/stderr"; then
  pass
else
  fail "a malformed npm-dir manifest must surface the parse error (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 36. the root manifest is consulted only when the package manifest has no
# license; a malformed one then warns, as detect-license does, instead of
# silently reporting that no license exists.
new_case malformed-root-manifest-warns
printf '{"name":"@scope/app","version":"1.0.0"}\n' > "$DIR/npm/package.json"
printf '{not json\n' > "$DIR/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] &&
  grep -q '::warning::Could not parse package.json' "$DIR/stderr"; then
  pass
else
  fail "a malformed root manifest must warn instead of being swallowed (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 37. a malformed platform manifest is a parse error, not a missing license
new_case malformed-platform-manifest
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
printf '{not json\n' > "$DIR/platforms/app-linux-x64/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] &&
  grep -q 'Could not parse .*app-linux-x64/package.json' "$DIR/stderr"; then
  pass
else
  fail "a malformed platform manifest must surface the parse error (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

echo "license-lint: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
