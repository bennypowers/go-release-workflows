#!/usr/bin/env bash
# Shared license-file discovery for composite action scripts.
#
# Source from a script with:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/license.sh"
#
# Keep the candidate list and the package-directory precedence here so every
# action resolves licenses identically. The two callers are stage-license (the
# release path) and license-lint (the CI path); if they disagree, CI passes a
# layout that the release then rejects.
#
# Discovery is intentionally strict. A file merely starting with LICENSE is not
# a license: LICENSE-check.js, LICENSE-HEADER.txt and LICENSE-THIRD-PARTY are
# tooling and notices, not the package license. Accepted names are:
#   - LICENSE, LICENCE, COPYING, optionally with .md/.txt/.rst/.html
#   - LICENSE-<SPDX-id>, for ids in spdx-license-ids.txt and a few short forms
# All matching is case-insensitive. Two names for the same inode (as reported
# on a case-insensitive filesystem) count once.
#
# Follow-up (deliberately not implemented here): cross-check the declared SPDX
# identifier against the text of the license file. That needs an SPDX text
# matcher and is tracked separately; this module only establishes the file.

_LICENSE_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_LICENSE_SPDX_FILE="$_LICENSE_LIB_DIR/spdx-license-ids.txt"
# Conventional short forms that are not themselves SPDX ids. LICENSE-MIT plus
# LICENSE-APACHE is the canonical dual-license layout and must be ambiguous.
_LICENSE_FILE_ALIASES=" apache bsd gpl lgpl agpl mpl epl cddl isc zlib boost wtfpl unlicense cc0 public-domain "

# _license_lower <string>
_license_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# _license_scan_list <dir>
# Prints the path of a NUL-separated list of top-level entries. The caller owns
# the file and must remove it. Returns non-zero when find fails, so callers do
# not silently treat an unreadable directory as license-free.
_license_scan_list() {
  local dir="$1" raw list
  raw=$(mktemp "${TMPDIR:-/tmp}/license-scan.XXXXXX") || return 1
  list=$(mktemp "${TMPDIR:-/tmp}/license-scan.XXXXXX") || {
    rm -f -- "$raw"
    return 1
  }
  if ! find -- "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' -print0 >"$raw" 2>/dev/null; then
    rm -f -- "$raw" "$list"
    return 1
  fi
  # Sorted output keeps the winner deterministic when two names share an
  # inode. BSD sort lacks -z; fall back to find's order there.
  if ! LC_ALL=C sort -z -- "$raw" >"$list" 2>/dev/null; then
    if ! cp -- "$raw" "$list"; then
      rm -f -- "$raw" "$list"
      return 1
    fi
  fi
  rm -f -- "$raw"
  printf '%s' "$list"
}

# _license_inode_key <path>
# Follows symlinks when possible. Falls back to the link itself for dangling
# links. Supports GNU and BSD stat.
_license_inode_key() {
  local path="$1"
  stat -Lc '%d:%i' -- "$path" 2>/dev/null && return 0
  stat -Lf '%d:%i' -- "$path" 2>/dev/null && return 0
  stat -c '%d:%i' -- "$path" 2>/dev/null && return 0
  stat -f '%d:%i' -- "$path" 2>/dev/null
}

# _license_link_target <symlink>
# Prints the target path, resolving a relative target against the link's
# directory. Does not require the target to exist.
_license_link_target() {
  local link="$1" target
  target=$(readlink -- "$link") || return 1
  if [[ "$target" != /* ]]; then
    target="$(dirname -- "$link")/$target"
  fi
  printf '%s' "$target"
}

# _license_name_control_ok <basename>
# Fails for license-like names containing control characters (notably a
# newline), which cannot safely flow through $GITHUB_OUTPUT or a cp operand.
_license_name_control_ok() {
  local base="$1" lower
  lower=$(_license_lower "$base")
  case "$lower" in
    license* | licence* | copying*) ;;
    *) return 0 ;;
  esac
  if [[ "$base" =~ [[:cntrl:]] ]]; then
    printf '::error::License filename contains control characters: %q\n' "$base" >&2
    return 1
  fi
}

# _match_license_name <basename>
# Returns 0 only for a real conventional license filename.
_match_license_name() {
  local base="$1" lower suffix
  lower=$(_license_lower "$base")
  case "$lower" in
    license | licence | copying) return 0 ;;
    license.md | license.txt | license.rst | license.html) return 0 ;;
    licence.md | licence.txt | licence.rst | licence.html) return 0 ;;
    copying.md | copying.txt | copying.rst | copying.html) return 0 ;;
    license-*) suffix="${lower#license-}" ;;
    *) return 1 ;;
  esac
  [[ -n "$suffix" ]] || return 1
  # The suffix must be an SPDX license id (case-insensitively, because file
  # names vary) or one of the conventional short forms above. This is what
  # keeps LICENSE-check.js, LICENSE-HEADER.txt and LICENSE-THIRD-PARTY out.
  if [[ -f "$_LICENSE_SPDX_FILE" ]] && grep -Fxiq -- "$suffix" "$_LICENSE_SPDX_FILE"; then
    return 0
  fi
  case "$_LICENSE_FILE_ALIASES" in
    *" $suffix "*) return 0 ;;
  esac
  return 1
}

# discover_license_file <explicit-path> [purpose]
# Sets LICENSE_SRC and LICENSE_NAME, or returns non-zero with an ::error::.
# An explicit path wins. Without one, exactly one conventional file must exist:
# ambiguity (for example LICENSE-MIT plus LICENSE-APACHE) is an error, because
# silently shipping one half of a dual license is a compliance bug.
# shellcheck disable=SC2094 # the temp scan file is only deleted after reading
discover_license_file() {
  local explicit="${1:-}" purpose="${2:-the package}" list path rel base key
  local -a candidates=() empties=()
  local seen=" "
  LICENSE_SRC=""
  LICENSE_NAME=""

  if [[ -n "$explicit" ]]; then
    if [[ ! -e "$explicit" ]]; then
      printf '::error::License file not found: %s\n' "$explicit" >&2
      return 1
    fi
    if [[ ! -f "$explicit" ]]; then
      printf '::error::License file is not a regular file: %s\n' "$explicit" >&2
      return 1
    fi
    if [[ ! -s "$explicit" ]]; then
      printf '::error::License file is empty: %s\n' "$explicit" >&2
      return 1
    fi
    LICENSE_SRC="$explicit"
  else
    if ! list=$(_license_scan_list .); then
      printf '::error::Could not scan %s for license files\n' "$(pwd)" >&2
      return 1
    fi
    while IFS= read -r -d '' path; do
      rel="${path#./}"
      base=$(basename -- "$rel")
      # Control characters in a license-like name are fatal, not ignored: the
      # user almost certainly meant it to be the license.
      _license_name_control_ok "$base" || {
        rm -f -- "$list"
        return 1
      }
      _match_license_name "$base" || continue
      key=$(_license_inode_key "$path") || key=""
      if [[ -n "$key" ]]; then
        case "$seen" in
          *" $key "*) continue ;;
        esac
        seen="$seen$key "
      fi
      if [[ -f "$path" && -s "$path" ]]; then
        candidates+=("$rel")
      else
        empties+=("$rel")
      fi
    done <"$list"
    rm -f -- "$list"

    if [[ ${#candidates[@]} -eq 0 ]]; then
      if [[ ${#empties[@]} -gt 0 ]]; then
        printf '::error::License file is empty: %s; %s must ship a non-empty license (write the license text or set the license-file input)\n' "${empties[*]}" "$purpose" >&2
      else
        printf '::error::No license file found in %s; %s must include one (set the license-file input or add LICENSE to the repository)\n' "$(pwd)" "$purpose" >&2
      fi
      return 1
    fi
    if [[ ${#candidates[@]} -gt 1 ]]; then
      printf '::error::Multiple license files found: %s; set the license-file input to choose one\n' "${candidates[*]}" >&2
      return 1
    fi
    LICENSE_SRC="${candidates[0]}"
  fi

  LICENSE_NAME=$(basename -- "$LICENSE_SRC")

  # The basename is written to $GITHUB_OUTPUT as a key=value line, so control
  # characters (notably newlines) would corrupt the output file.
  if [[ "$LICENSE_NAME" =~ [[:cntrl:]] ]]; then
    printf '::error::License filename contains control characters: %q\n' "$LICENSE_NAME" >&2
    return 1
  fi
}

# _collect_package_licenses <npm-dir>
# Populates:
#   PKG_CANDIDATE_PATHS   non-empty license payloads (symlinks dereferenced)
#   PKG_CANDIDATE_NAMES   the names those payloads would ship under
#   PKG_EMPTY_NAMES       license names holding no text
#   PKG_ALL_NAMES         every strict license name in the directory
#   PKG_SYMLINK_NAMES     names that arrived as symlinks
# Fails on a broken, unreadable or empty symlink target, and on scan failure.
# shellcheck disable=SC2094 # the temp scan file is only deleted after reading
_collect_package_licenses() {
  local dir="$1" list path base key target
  local seen=" "
  PKG_CANDIDATE_PATHS=()
  PKG_CANDIDATE_NAMES=()
  PKG_EMPTY_NAMES=()
  PKG_ALL_NAMES=()
  PKG_SYMLINK_NAMES=()

  if ! list=$(_license_scan_list "$dir"); then
    printf '::error::Could not scan %s for license files\n' "$dir" >&2
    return 1
  fi
  while IFS= read -r -d '' path; do
    base=$(basename -- "$path")
    _license_name_control_ok "$base" || {
      rm -f -- "$list"
      return 1
    }
    _match_license_name "$base" || continue
    PKG_ALL_NAMES+=("$base")

    if [[ -L "$path" ]]; then
      if [[ ! -e "$path" ]]; then
        printf '::error::License symlink %s is broken: its target is missing. Replace it with a real license file or remove it.\n' "$path" >&2
        rm -f -- "$list"
        return 1
      fi
      if [[ ! -f "$path" ]]; then
        printf '::error::License symlink %s does not point to a regular file\n' "$path" >&2
        rm -f -- "$list"
        return 1
      fi
      if [[ ! -r "$path" ]]; then
        printf '::error::License symlink %s points to an unreadable file\n' "$path" >&2
        rm -f -- "$list"
        return 1
      fi
      if [[ ! -s "$path" ]]; then
        printf '::error::License symlink %s points to an empty file; write the license text there or remove the symlink\n' "$path" >&2
        rm -f -- "$list"
        return 1
      fi
      target=$(_license_link_target "$path") || {
        printf '::error::Could not resolve license symlink %s\n' "$path" >&2
        rm -f -- "$list"
        return 1
      }
      key=$(_license_inode_key "$path") || key=""
      if [[ -n "$key" ]]; then
        case "$seen" in
          *" $key "*) continue ;;
        esac
        seen="$seen$key "
      fi
      PKG_CANDIDATE_PATHS+=("$target")
      PKG_CANDIDATE_NAMES+=("$base")
      PKG_SYMLINK_NAMES+=("$base")
      continue
    fi

    [[ -f "$path" ]] || continue
    if [[ ! -s "$path" ]]; then
      PKG_EMPTY_NAMES+=("$base")
      continue
    fi
    key=$(_license_inode_key "$path") || key=""
    if [[ -n "$key" ]]; then
      case "$seen" in
        *" $key "*) continue ;;
      esac
      seen="$seen$key "
    fi
    PKG_CANDIDATE_PATHS+=("$path")
    PKG_CANDIDATE_NAMES+=("$base")
  done <"$list"
  rm -f -- "$list"
}

# resolve_license <npm-dir> <explicit-path> [purpose]
# Sets:
#   RESOLVED_LICENSE_SRC    file whose contents are staged
#   RESOLVED_LICENSE_NAME   basename to stage under
#   RESOLVED_FROM_PACKAGE   1 when the package's own license won
#   RESOLVED_REMOVE_NAMES   license names to delete before copying
#   RESOLVED_PACKAGE_SYMLINK 1 when the package license arrived as a symlink
#
# Precedence:
#   1. explicit license-file: the user named this file, so it wins over the
#      package's own license.
#   2. the package's own license (a differently named one included), because
#      staging a second license would make the tarball ambiguous.
#   3. the repository license.
# shellcheck disable=SC2034 # results are consumed by the caller
resolve_license() {
  local npm_dir="$1" explicit="${2:-}" purpose="${3:-the package}" name
  RESOLVED_LICENSE_SRC=""
  RESOLVED_LICENSE_NAME=""
  RESOLVED_FROM_PACKAGE=0
  RESOLVED_REMOVE_NAMES=()
  RESOLVED_PACKAGE_SYMLINK=0

  _collect_package_licenses "$npm_dir" || return 1

  if [[ -n "$explicit" ]]; then
    discover_license_file "$explicit" "$purpose" || return 1
    RESOLVED_LICENSE_SRC="$LICENSE_SRC"
    RESOLVED_LICENSE_NAME="$LICENSE_NAME"
    RESOLVED_REMOVE_NAMES=("${PKG_ALL_NAMES[@]}")
    return 0
  fi

  if [[ ${#PKG_CANDIDATE_NAMES[@]} -gt 1 ]]; then
    printf '::error::Multiple license files found in %s: %s; set the license-file input to choose one\n' \
      "$npm_dir" "${PKG_CANDIDATE_NAMES[*]}" >&2
    return 1
  fi

  RESOLVED_REMOVE_NAMES=("${PKG_EMPTY_NAMES[@]}")

  if [[ ${#PKG_CANDIDATE_NAMES[@]} -eq 1 ]]; then
    RESOLVED_LICENSE_SRC="${PKG_CANDIDATE_PATHS[0]}"
    RESOLVED_LICENSE_NAME="${PKG_CANDIDATE_NAMES[0]}"
    RESOLVED_FROM_PACKAGE=1
    # Remove duplicate names for the same inode and any leftover empty names.
    for name in "${PKG_ALL_NAMES[@]}"; do
      [[ "$name" == "$RESOLVED_LICENSE_NAME" ]] && continue
      RESOLVED_REMOVE_NAMES+=("$name")
    done
    for name in "${PKG_SYMLINK_NAMES[@]}"; do
      [[ "$name" == "$RESOLVED_LICENSE_NAME" ]] && RESOLVED_PACKAGE_SYMLINK=1
    done
    # A symlink must be removed before the real file takes its place.
    if [[ "$RESOLVED_PACKAGE_SYMLINK" -eq 1 ]]; then
      RESOLVED_REMOVE_NAMES+=("$RESOLVED_LICENSE_NAME")
    fi
    return 0
  fi

  discover_license_file "" "$purpose" || return 1
  RESOLVED_LICENSE_SRC="$LICENSE_SRC"
  RESOLVED_LICENSE_NAME="$LICENSE_NAME"
}

# stage_resolved_license <dir> <name> <src> [names-to-remove...]
# Snapshots the source first, so the source may be one of the removed paths and
# a symlink is always dereferenced into a regular file. The snapshot also
# covers an explicit license-file that lives inside <dir>.
stage_resolved_license() {
  local dir="$1" name="$2" src="$3" tmp n
  shift 3
  tmp=$(mktemp "${TMPDIR:-/tmp}/license-stage.XXXXXX") || {
    echo "::error::Could not create a temporary file to stage the license" >&2
    return 1
  }
  if ! cp -- "$src" "$tmp"; then
    rm -f -- "$tmp"
    printf '::error::Could not read license file: %s\n' "$src" >&2
    return 1
  fi
  for n in "$@"; do
    if ! rm -f -- "$dir/$n"; then
      rm -f -- "$tmp"
      printf '::error::Could not remove stale license file: %s/%s\n' "$dir" "$n" >&2
      return 1
    fi
  done
  if ! cp -- "$tmp" "$dir/$name"; then
    rm -f -- "$tmp"
    printf '::error::Could not write license file: %s/%s\n' "$dir" "$name" >&2
    return 1
  fi
  rm -f -- "$tmp"
}
