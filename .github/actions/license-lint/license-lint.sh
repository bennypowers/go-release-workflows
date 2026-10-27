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

# 1. The license file itself. Every project that releases artifacts should
# carry one, npm or not; it is what the archive or tarball ships.
# shellcheck source=.github/actions/lib/license.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/license.sh"
if ! discover_license_file "$LICENSE_FILE" "the release"; then
  errors=$((errors + 1))
fi

if [[ -n "${LICENSE_NAME:-}" ]]; then
  if [[ -L "$LICENSE_SRC" ]]; then
    note "source license $LICENSE_SRC is a symlink; release packaging copies its contents as a real file"
  fi
  note "license file: $LICENSE_SRC -> $LICENSE_NAME"
fi

# 2. Does this project publish npm packages?
PRIMARY_MANIFEST="$NPM_DIR/package.json"
NPM_PACKAGES=0
if [[ "$NPM_MODE" == "none" ]]; then
  note "npm-mode=none; skipped npm package checks"
elif [[ -f "$PRIMARY_MANIFEST" ]]; then
  NPM_PACKAGES=1
elif [[ "$NPM_MODE" == "required" ]]; then
  err "$PRIMARY_MANIFEST not found; npm-mode=required needs a package manifest (set npm-dir, pass npm-mode=auto for a repository without npm packages, or npm-mode=none)"
else
  note "no $PRIMARY_MANIFEST; linting the repository license only (npm-mode=auto)"
fi

# 3. The SPDX identifier the release publishes, when there is one to check.
if [[ "$NPM_PACKAGES" -eq 1 || -n "$EXPLICIT_LICENSE" ]]; then
  MANIFEST_LICENSE=""
  [[ "$NPM_PACKAGES" -eq 1 ]] && MANIFEST_LICENSE=$(manifest_license "$PRIMARY_MANIFEST")

  LICENSE="${EXPLICIT_LICENSE:-}"
  if [[ -n "$LICENSE" ]]; then
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

  if [[ -z "$LICENSE" ]]; then
    err "no SPDX license found: set a license input or add a license field to $PRIMARY_MANIFEST"
  elif [[ "$(printf '%s' "$LICENSE" | tr -d '[:space:]')" == "NOASSERTION" || "$LICENSE" == "null" ]]; then
    err "license '$LICENSE' is not a publishable identifier"
  elif ! valid_spdx "$LICENSE"; then
    err "license '$LICENSE' is not a valid SPDX expression; allowed characters are letters, digits, '.', '+', '(', ')', ' ', and '-' (e.g. MIT, GPL-3.0-or-later)"
  fi
else
  # Repository without npm packages: a license file is enough to release. If
  # the project carries SPDX metadata, use it, but do not invent a failure for
  # projects that record their license only in the license file itself.
  LICENSE="${EXPLICIT_LICENSE:-$(manifest_license package.json)}"
  if [[ -n "$LICENSE" ]] && ! valid_spdx "$LICENSE"; then
    err "license '$LICENSE' is not a valid SPDX expression"
  fi
  [[ -n "$LICENSE" ]] || note "no SPDX metadata found; the release will publish the license file only"
fi

# packlist <dir> prints the files npm would publish, or fails.
packlist() {
  local dir="$1" json
  json=$(cd "$dir" && npm pack --dry-run --json --ignore-scripts 2>/dev/null) || return 1
  jq -r '.[0].files[]?.path' <<<"$json" 2>/dev/null
}

# 4. The main package tarball must contain the license.
if [[ "$NPM_PACKAGES" -eq 1 && -n "${LICENSE_NAME:-}" ]]; then
  if PACKED=$(packlist "$NPM_DIR"); then
    if ! grep -qxF -- "$LICENSE_NAME" <<<"$PACKED"; then
      err "main package tarball would not include $LICENSE_NAME; add it to the files list in $PRIMARY_MANIFEST"
    else
      note "main package tarball includes $LICENSE_NAME"
    fi
  else
    note "could not run npm pack in $NPM_DIR; skipped main tarball check"
  fi
fi

# 5. Every platform package must ship the license and say so in its manifest.
platform_count=0
if [[ "$NPM_PACKAGES" -eq 1 && -d "$PLATFORMS_DIR" ]]; then
  while IFS= read -r pkgdir; do
    platform_count=$((platform_count + 1))
    pkg_json="$pkgdir/package.json"
    if [[ ! -f "$pkg_json" ]]; then
      err "$pkgdir has no package.json"
      continue
    fi
    pkg_license=$(jq -r '.license // empty' "$pkg_json" 2>/dev/null || true)
    if [[ -z "$pkg_license" ]]; then
      err "$pkg_json has no license field"
    elif [[ -n "${LICENSE:-}" && "$pkg_license" != "$LICENSE" ]]; then
      err "$pkg_json publishes '$pkg_license' but the release publishes '$LICENSE'"
    fi

    if [[ -n "${LICENSE_NAME:-}" ]]; then
      if [[ ! -f "$pkgdir/$LICENSE_NAME" ]]; then
        err "$pkgdir does not contain $LICENSE_NAME; the published platform tarball would have no license"
      elif [[ -L "$pkgdir/$LICENSE_NAME" ]]; then
        err "$pkgdir/$LICENSE_NAME is a symlink; publish a real file"
      elif PACKED=$(packlist "$pkgdir"); then
        if ! grep -qxF -- "$LICENSE_NAME" <<<"$PACKED"; then
          err "$pkgdir tarball would not include $LICENSE_NAME; add it to the files list in $pkg_json"
        fi
      else
        note "could not run npm pack in $pkgdir; skipped its tarball check"
      fi
    fi
  done < <(find "$PLATFORMS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
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
    [[ -n "${LICENSE_NAME:-}" ]] && echo "license-file=$LICENSE_NAME"
    echo "platform-packages=$platform_count"
  } >> "$GITHUB_OUTPUT"
fi

echo "✓ license-lint passed: ${LICENSE:-license file only}${LICENSE_NAME:+, $LICENSE_NAME}, $platform_count platform package(s), npm packages: $NPM_PACKAGES" >&2
