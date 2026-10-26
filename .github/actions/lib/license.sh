#!/usr/bin/env bash
# Shared license-file discovery for composite action scripts.
#
# Source from a script with:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/license.sh"
#
# Keep the candidate list here so every action resolves licenses identically.

# discover_license_file <explicit-path> [purpose]
# Sets LICENSE_SRC and LICENSE_NAME, or returns non-zero with an ::error::.
# An explicit path wins. Without one, exactly one conventional file must exist:
# ambiguity (for example LICENSE-MIT plus LICENSE-APACHE) is an error, because
# silently shipping one half of a dual license is a compliance bug.
discover_license_file() {
  local explicit="${1:-}" purpose="${2:-the package}" candidate
  local -a candidates=()
  LICENSE_SRC=""
  LICENSE_NAME=""

  if [[ -n "$explicit" ]]; then
    if [[ ! -f "$explicit" ]]; then
      echo "::error::License file not found: $explicit" >&2
      return 1
    fi
    if [[ ! -s "$explicit" ]]; then
      echo "::error::License file is empty: $explicit" >&2
      return 1
    fi
    LICENSE_SRC="$explicit"
  else
    # Lowercase forms are matched exactly or with an extension (license.md),
    # not by prefix: a file like license-check.js is not a license.
    for candidate in LICENSE* LICENCE* COPYING* license license.* licence licence.* copying copying.*; do
      if [[ -f "$candidate" && -s "$candidate" ]]; then
        candidates+=("$candidate")
      fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
      echo "::error::No license file found in $(pwd); ${purpose} must include one (set the license-file input or add LICENSE to the repository)" >&2
      return 1
    fi
    if [[ ${#candidates[@]} -gt 1 ]]; then
      printf '::error::Multiple license files found: %s; set the license-file input to choose one\n' "${candidates[*]}" >&2
      return 1
    fi
    LICENSE_SRC="${candidates[0]}"
  fi

  LICENSE_NAME=$(basename "$LICENSE_SRC")

  # The basename is written to $GITHUB_OUTPUT as a key=value line, so control
  # characters (notably newlines) would corrupt the output file.
  if [[ "$LICENSE_NAME" =~ [[:cntrl:]] ]]; then
    printf '::error::License filename contains control characters: %q\n' "$LICENSE_NAME" >&2
    return 1
  fi
}
