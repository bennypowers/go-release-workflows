#!/usr/bin/env bash
set -euo pipefail

# Lint license compliance for a release, whether or not the project publishes
# npm packages.
#
# Fails early, in a normal test workflow, for the conditions that otherwise
# break a release: missing or empty license file, missing or invalid SPDX
# license, and npm packages that would ship without a license file or without
# listing it in their tarball.
#
# The main package check mirrors the release: it stages the license into a
# temporary copy of npm-dir (the same precedence and symlink handling as
# stage-license) and then asks npm for that copy's packlist. Packing npm-dir
# directly would reject the canonical layout, where the license does not exist
# until stage-license runs at publish time.
#
# Usage:
#   license-lint.sh [npm-dir] [license-file] [license] [platforms-dir] [npm-mode]
#
# npm-mode:
#   auto      (default) lint npm packages when npm-dir holds a package.json;
#             otherwise lint the repository license only
#   required  fail when npm-dir has no package.json
#   none      skip every npm check; only the repository license is linted
#
# Outputs (via $GITHUB_OUTPUT when set):
#   license=<SPDX>            when one could be determined
#   license-file=<basename>   when a license file was found
#   platform-packages=<count> platform packages checked (0 when none)

NPM_DIR="${1:-npm}"
LICENSE_FILE="${2:-}"
EXPLICIT_LICENSE="${3:-}"
PLATFORMS_DIR="${4:-platforms}"
NPM_MODE="${5:-auto}"

NPM_DIR="${NPM_DIR%/}"
[[ -n "$NPM_DIR" ]] || NPM_DIR="."

case "$NPM_MODE" in
  auto | required | none) ;;
  *)
    echo "::error::license-lint: npm-mode must be auto, required, or none; got '$NPM_MODE'" >&2
    exit 2
    ;;
esac

errors=0
notes=()
note() { notes+=("$1"); }
err() {
  echo "::error::$1" >&2
  errors=$((errors + 1))
}

manifest_license() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 0
  jq -r '
    if (.license | type) == "object" then (.license.type | select(type == "string"))
    elif (.license | type) == "string" then .license
    elif (.licenses | type) == "array" then
      (.licenses[0] | if type == "object" then (.type | select(type == "string")) else empty end)
    else empty
    end
  ' "$manifest" 2>/dev/null || true
}

valid_spdx() {
  local value="$1"
  local pattern='^[A-Za-z0-9.+() -]+$'
  local file_ref='^SEE LICENSE IN [A-Za-z0-9._+()/ -]+$'
  [[ "$value" =~ [[:cntrl:]] ]] && return 1
  [[ "$value" =~ $file_ref ]] && return 0
  [[ "$value" =~ $pattern ]]
}

# check_license_value <value> <source>
# Rejects empty, NOASSERTION/null, and invalid SPDX values consistently in the
# npm and no-npm paths.
check_license_value() {
  local value="$1" source="$2"
  if [[ -z "$value" ]]; then
    err "no SPDX license found: set a license input or add a license field to $source"
    return 1
  fi
  if [[ "$(printf '%s' "$value" | tr -d '[:space:]')" == "NOASSERTION" || "$value" == "null" ]]; then
    err "license '$value' from $source is not a publishable identifier"
    return 1
  fi
  if ! valid_spdx "$value"; then
    err "license '$value' from $source is not a valid SPDX expression; allowed characters are letters, digits, '.', '+', '(', ')', ' ', and '-' (e.g. MIT, GPL-3.0-or-later)"
    return 1
  fi
  return 0
}

# copy_tree <src> <dest>
# Copies npm-dir into the temporary staging directory, excluding .git, which
# npm never packs. Falls back to cp when tar is unavailable.
copy_tree() {
  local src="$1" dest="$2"
  if command -v tar >/dev/null 2>&1; then
    (cd -- "$src" && tar -cf - --exclude=.git .) | (cd -- "$dest" && tar -xf -)
  else
    cp -R -- "$src/." "$dest/"
  fi
}

# packlist_contains <basename> <newline-separated paths>
# npm packlist paths are normally relative, but compare the last component so
# an absolute or nested path still identifies the license.
packlist_contains() {
  local name="$1" list="$2" path norm
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    norm="${path//\\//}"
    if [[ "$norm" == "$name" || "$norm" == */"$name" ]]; then
      return 0
    fi
  done <<<"$list"
  return 1
}

# packlist <dir>
# Prints the packed file paths, or returns non-zero after writing the reason
# (including npm's own stderr) to stderr. Failures are never treated as an
# empty packlist.
packlist() {
  local dir="$1" json errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/license-lint-pack.XXXXXX") || {
    echo "::error::license-lint: could not create a temporary file for npm pack" >&2
    return 1
  }
  if ! json=$(cd -- "$dir" && npm pack --dry-run --json --ignore-scripts 2>"$errfile"); then
    printf 'npm pack failed in %s: %s\n' "$dir" "$(cat -- "$errfile")" >&2
    rm -f -- "$errfile"
    return 1
  fi
  if [[ -s "$errfile" ]]; then
    printf 'npm pack warning in %s: %s\n' "$dir" "$(cat -- "$errfile")" >&2
  fi
  rm -f -- "$errfile"
  if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$json"; then
    printf 'npm pack in %s did not return JSON: %s\n' "$dir" "${json:-<empty output>}" >&2
    return 1
  fi
  jq -r '.[0].files[]?.path // empty' <<<"$json"
}

# check_pack <dir> <license-name> <label> <manifest>
check_pack() {
  local dir="$1" name="$2" label="$3" manifest="$4" packed
  if ! command -v npm >/dev/null 2>&1; then
    err "npm not found; $label needs npm pack to verify its tarball (install Node.js or set npm-mode=none)"
    return 1
  fi
  if ! packed=$(packlist "$dir"); then
    err "npm pack failed in $dir while checking the $label"
    return 1
  fi
  if ! packlist_contains "$name" "$packed"; then
    err "$label tarball would not include $name; add it to the files list in $manifest"
    return 1
  fi
  note "$label tarball includes $name"
  return 0
}

# 1. The license file. For npm packages, resolve the same precedence that
# stage-license applies to the main package. Platform packages always use the
# repository (or explicit) license, since generate-platform-pkg does.
# shellcheck source=.github/actions/lib/license.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/license.sh"

LICENSE_RESOLVED=0
MAIN_LICENSE_NAME=""
PLATFORM_LICENSE_NAME=""
RESOLVED_FROM_PACKAGE=0
RESOLVED_PACKAGE_SYMLINK=0

# 2. Does this project publish npm packages?
PRIMARY_MANIFEST="$NPM_DIR/package.json"
NPM_PACKAGES=0
if [[ "$NPM_MODE" == "none" ]]; then
  note "npm-mode=none; skipped npm package checks"
elif [[ -f "$PRIMARY_MANIFEST" ]]; then
  NPM_PACKAGES=1
elif [[ "$NPM_MODE" == "required" ]]; then
  err "$PRIMARY_MANIFEST not found; npm-mode=required needs a package manifest (set npm-dir, pass npm-mode=auto for a repository without npm packages, or npm-mode=none)"
elif [[ -f package.json ]] &&
  jq -e '(.name | type == "string") and (.private != true)' package.json >/dev/null 2>&1; then
  # Auto must not turn a typo'd npm-dir into a silent pass when the root
  # manifest says this project publishes a package.
  err "$PRIMARY_MANIFEST not found, but package.json is a publishable manifest; set npm-dir to the package directory, or pass npm-mode=none to skip npm checks"
else
  note "no $PRIMARY_MANIFEST; linting the repository license only (npm-mode=auto)"
fi

if [[ "$NPM_PACKAGES" -eq 1 ]]; then
  if resolve_license "$NPM_DIR" "$LICENSE_FILE" "the main package"; then
    LICENSE_RESOLVED=1
    MAIN_LICENSE_NAME="$RESOLVED_LICENSE_NAME"
    note "main license file: $RESOLVED_LICENSE_SRC -> $MAIN_LICENSE_NAME"
    if [[ "$RESOLVED_PACKAGE_SYMLINK" -eq 1 ]]; then
      note "the main package license is staged from a symlink target as a real file"
    fi
  else
    errors=$((errors + 1))
  fi
  if [[ "$LICENSE_RESOLVED" -eq 1 ]]; then
    if [[ "$RESOLVED_FROM_PACKAGE" -eq 0 ]]; then
      # The main package already uses the repository/explicit license.
      PLATFORM_LICENSE_NAME="$MAIN_LICENSE_NAME"
    elif discover_license_file "$LICENSE_FILE" "platform packages"; then
      PLATFORM_LICENSE_NAME="$LICENSE_NAME"
      note "platform license file: $LICENSE_SRC -> $PLATFORM_LICENSE_NAME"
    else
      errors=$((errors + 1))
    fi
  fi
else
  if discover_license_file "$LICENSE_FILE" "the release"; then
    LICENSE_RESOLVED=1
    MAIN_LICENSE_NAME="$LICENSE_NAME"
    PLATFORM_LICENSE_NAME="$LICENSE_NAME"
    note "license file: $LICENSE_SRC -> $LICENSE_NAME"
    if [[ -L "$LICENSE_SRC" ]]; then
      note "source license $LICENSE_SRC is a symlink; release packaging copies its contents as a real file"
    fi
  else
    errors=$((errors + 1))
  fi
fi

# 3. The SPDX identifier the release publishes.
LICENSE=""
MANIFEST_LICENSE=""
ROOT_LICENSE=""
if [[ "$NPM_PACKAGES" -eq 1 ]]; then
  MANIFEST_LICENSE=$(manifest_license "$PRIMARY_MANIFEST")
  if [[ -n "$EXPLICIT_LICENSE" ]]; then
    LICENSE="$EXPLICIT_LICENSE"
    if [[ -n "$MANIFEST_LICENSE" && "$LICENSE" != "$MANIFEST_LICENSE" ]]; then
      err "license input '$LICENSE' does not match $PRIMARY_MANIFEST license '$MANIFEST_LICENSE'; the release would publish one value and the manifest would claim another"
    fi
  else
    LICENSE="$MANIFEST_LICENSE"
    if [[ -z "$LICENSE" ]]; then
      ROOT_LICENSE=$(manifest_license package.json)
      if [[ -n "$ROOT_LICENSE" ]]; then
        LICENSE="$ROOT_LICENSE"
        note "license taken from repository package.json: $LICENSE"
        if [[ "$NPM_DIR" != "." ]]; then
          err "$PRIMARY_MANIFEST has no license field, but the release publishes the repository value '$LICENSE'; add it to the package manifest so the published tarball is self-describing"
        fi
      fi
    fi
  fi
  check_license_value "$LICENSE" "$PRIMARY_MANIFEST" || true
else
  ROOT_LICENSE=$(manifest_license package.json)
  if [[ -n "$EXPLICIT_LICENSE" ]]; then
    LICENSE="$EXPLICIT_LICENSE"
    if [[ -n "$ROOT_LICENSE" && "$LICENSE" != "$ROOT_LICENSE" ]]; then
      err "license input '$LICENSE' does not match package.json license '$ROOT_LICENSE'; the release would publish one value and the manifest would claim another"
    fi
    check_license_value "$LICENSE" "the license input" || true
  elif [[ -n "$ROOT_LICENSE" ]]; then
    LICENSE="$ROOT_LICENSE"
    check_license_value "$LICENSE" "package.json" || true
  else
    note "no SPDX metadata found; the release will publish the license file only"
  fi
fi

# 4. The main package tarball must contain the license. Stage into a temporary
# copy first, exactly as the release will.
if [[ "$NPM_PACKAGES" -eq 1 && "$LICENSE_RESOLVED" -eq 1 ]]; then
  TMP_NPM=""
  if ! TMP_NPM=$(mktemp -d "${TMPDIR:-/tmp}/license-lint-npm.XXXXXX"); then
    err "could not create a temporary directory to stage the main package license"
  else
    if ! copy_tree "$NPM_DIR" "$TMP_NPM"; then
      err "could not copy $NPM_DIR into a temporary directory for npm pack"
    elif ! stage_resolved_license "$TMP_NPM" "$MAIN_LICENSE_NAME" "$RESOLVED_LICENSE_SRC" \
      ${RESOLVED_REMOVE_NAMES[@]+"${RESOLVED_REMOVE_NAMES[@]}"}; then
      err "could not stage $MAIN_LICENSE_NAME into the temporary package copy"
    elif [[ -L "$TMP_NPM/$MAIN_LICENSE_NAME" ]]; then
      err "main package license $NPM_DIR/$MAIN_LICENSE_NAME is a symlink; publish a real file"
    else
      check_pack "$TMP_NPM" "$MAIN_LICENSE_NAME" "main package" "$PRIMARY_MANIFEST" || true
    fi
    rm -rf -- "$TMP_NPM"
  fi
fi

# 5. Every platform package must ship the license and say so in its manifest.
platform_count=0
if [[ "$NPM_PACKAGES" -eq 1 && -d "$PLATFORMS_DIR" ]]; then
  platform_list=""
  if ! platform_list=$(_license_scan_list "$PLATFORMS_DIR"); then
    err "could not scan $PLATFORMS_DIR for platform packages"
  else
    # shellcheck disable=SC2094 # the temp scan file is only deleted after reading
    while IFS= read -r -d '' pkgdir; do
      [[ -d "$pkgdir" ]] || continue
      platform_count=$((platform_count + 1))
      pkg_json="$pkgdir/package.json"
      if [[ ! -f "$pkg_json" ]]; then
        err "$pkgdir has no package.json"
        continue
      fi
      pkg_license=$(jq -r '.license // empty' "$pkg_json" 2>/dev/null || true)
      if [[ -z "$pkg_license" ]]; then
        err "$pkg_json has no license field"
      elif [[ -n "$LICENSE" && "$pkg_license" != "$LICENSE" ]]; then
        err "$pkg_json publishes '$pkg_license' but the release publishes '$LICENSE'"
      fi

      if [[ "$LICENSE_RESOLVED" -eq 1 ]]; then
        if [[ ! -f "$pkgdir/$PLATFORM_LICENSE_NAME" ]]; then
          err "$pkgdir does not contain $PLATFORM_LICENSE_NAME; the published platform tarball would have no license"
        elif [[ -L "$pkgdir/$PLATFORM_LICENSE_NAME" ]]; then
          err "$pkgdir/$PLATFORM_LICENSE_NAME is a symlink; publish a real file"
        else
          check_pack "$pkgdir" "$PLATFORM_LICENSE_NAME" "$pkgdir" "$pkg_json" || true
        fi
      fi
    done <"$platform_list"
    rm -f -- "$platform_list"
  fi
  if [[ "$platform_count" -eq 0 ]]; then
    note "no platform packages under $PLATFORMS_DIR"
  fi
elif [[ "$NPM_PACKAGES" -eq 1 ]]; then
  note "no $PLATFORMS_DIR directory; skipped platform package checks"
fi

if [[ ${#notes[@]} -gt 0 ]]; then
  for line in "${notes[@]}"; do
    echo "license-lint: $line" >&2
  done
fi

if [[ $errors -gt 0 ]]; then
  echo "::error::license-lint found $errors problem(s); the release would fail or publish non-compliant packages" >&2
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    [[ -n "${LICENSE:-}" ]] && echo "license=$LICENSE"
    [[ -n "$MAIN_LICENSE_NAME" ]] && echo "license-file=$MAIN_LICENSE_NAME"
    echo "platform-packages=$platform_count"
  } >> "$GITHUB_OUTPUT"
fi

echo "✓ license-lint passed: ${LICENSE:-license file only}${MAIN_LICENSE_NAME:+, $MAIN_LICENSE_NAME}, $platform_count platform package(s), npm packages: $NPM_PACKAGES" >&2
