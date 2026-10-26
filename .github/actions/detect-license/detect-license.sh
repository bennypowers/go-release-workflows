#!/usr/bin/env bash
set -euo pipefail

# Detect the SPDX license identifier for npm package metadata.
#
# Precedence:
#   1. explicit-license input
#   2. <npm-dir>/package.json "license" field
#   3. repository root package.json "license" field
#   4. GitHub API (repos/<repository> license.spdx_id)
#
# GitHub normalizes licenses and cannot distinguish e.g. GPL-3.0 from
# GPL-3.0-or-later; only a manifest or an explicit input carries that detail.
# Empty and NOASSERTION values are rejected. There is no MIT default.
#
# Usage: detect-license.sh <repository> [explicit-license] [npm-dir]
# Example: detect-license.sh owner/repo
# Example: detect-license.sh owner/repo GPL-3.0-or-later npm
# Output: license=<SPDX> written to $GITHUB_OUTPUT

REPOSITORY="$1"
EXPLICIT_LICENSE="${2:-}"
NPM_DIR="${3:-npm}"

fail() {
  echo "::error::$1" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Print a usable license identifier, or nothing when the value is unusable.
normalize_license() {
  local value
  value=$(trim "$1")
  case "$value" in
    '' | 'null' | 'NOASSERTION') return 0 ;;
  esac
  printf '%s' "$value"
}

# Defense in depth: license values flow into generated package.json files and
# npm metadata, so only accept characters used by SPDX expressions.
validate_license() {
  local value="$1" source="$2" display
  local pattern='^[A-Za-z0-9.+() -]+$'
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    printf -v display '%q' "$value"
    fail "License $display from $source contains control characters; pass a valid SPDX expression (e.g. MIT, GPL-3.0-or-later)"
  fi
  if [[ ! "$value" =~ $pattern ]]; then
    fail "License '$value' from $source is not a valid SPDX expression; allowed characters are letters, digits, '.', '+', '(', ')', ' ', and '-' (e.g. MIT, GPL-3.0-or-later, (MIT OR Apache-2.0), SEE LICENSE IN LICENSE)"
  fi
}

# Read the license field from a package.json, supporting both the modern
# string form and the legacy object/array forms.
read_manifest_license() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 0
  local output status=0
  output=$(jq -r '
    if (.license | type) == "object" then .license.type
    elif (.license | type) == "string" then .license
    elif (.licenses | type) == "array" then (.licenses[0].type // empty)
    else empty
    end
  ' "$manifest" 2>/dev/null) || status=$?
  if [[ $status -ne 0 ]]; then
    echo "::warning::Could not parse $manifest as JSON; skipping its license field" >&2
    return 0
  fi
  printf '%s' "$output"
}

LICENSE=""
SOURCE=""

if [[ -n "$(trim "$EXPLICIT_LICENSE")" ]]; then
  LICENSE=$(normalize_license "$EXPLICIT_LICENSE")
  [[ -n "$LICENSE" ]] || fail "Explicit license '$EXPLICIT_LICENSE' is not a usable SPDX identifier"
  SOURCE="explicit license input"
else
  manifests=()
  if [[ -n "$NPM_DIR" && "$NPM_DIR" != "." && "$NPM_DIR" != "./" ]]; then
    manifests+=("${NPM_DIR%/}/package.json")
  fi
  manifests+=("package.json")

  for manifest in "${manifests[@]}"; do
    [[ -f "$manifest" ]] || continue
    LICENSE=$(normalize_license "$(read_manifest_license "$manifest")")
    if [[ -n "$LICENSE" ]]; then
      SOURCE="$manifest"
      break
    fi
  done

  if [[ -z "$LICENSE" ]]; then
    API_ERR=$(mktemp "${TMPDIR:-/tmp}/detect-license.XXXXXX")
    if API_OUT=$(gh api "repos/$REPOSITORY" --jq '.license.spdx_id // empty' 2>"$API_ERR"); then
      rm -f "$API_ERR"
      LICENSE=$(normalize_license "$API_OUT")
      if [[ -n "$LICENSE" ]]; then
        SOURCE="GitHub API"
      fi
    else
      API_STATUS=$?
      API_MESSAGE=$(cat "$API_ERR")
      rm -f "$API_ERR"
      fail "GitHub API request for $REPOSITORY failed (exit $API_STATUS): ${API_MESSAGE:-no error output}. Check that GH_TOKEN is set with repository read access and that the API rate limit has not been exceeded, or pass the 'license' input / set \"license\" in package.json."
    fi
  fi
fi

[[ -n "$LICENSE" ]] || fail \
  "Could not determine license for $REPOSITORY: pass the 'license' input, set \"license\" in $NPM_DIR/package.json or package.json, or use a license GitHub recognizes"

validate_license "$LICENSE" "$SOURCE"

echo "Detected license '$LICENSE' from $SOURCE" >&2
echo "license=$LICENSE" >> "$GITHUB_OUTPUT"
