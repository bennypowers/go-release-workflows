#!/usr/bin/env bash
set -euo pipefail

# Validate build outputs by comparing two artifact directories
# Usage: validate-build.sh <expected-dir> <actual-dir> [--strict]
# Example: validate-build.sh artifacts-old artifacts-new --strict
#
# Checks:
# - SHA256 hash match (--strict only)
# - File size within tolerance (default: exact match)
# - Architecture verification via `file` command
# - File existence

EXPECTED_DIR="$1"
ACTUAL_DIR="$2"
STRICT="${3:-}"

ERRORS=()
WARNINGS=()

log_error() {
  ERRORS+=("$1")
  echo "::error::$1"
}

log_warning() {
  WARNINGS+=("$1")
  echo "::warning::$1"
}

log_info() {
  echo "::notice::$1"
}

# Get all files from expected directory
if [[ ! -d "$EXPECTED_DIR" ]]; then
  log_error "Expected directory not found: $EXPECTED_DIR"
  exit 1
fi

if [[ ! -d "$ACTUAL_DIR" ]]; then
  log_error "Actual directory not found: $ACTUAL_DIR"
  exit 1
fi

EXPECTED_FILES=$(find "$EXPECTED_DIR" -type f -name "*" | sort)

for expected_file in $EXPECTED_FILES; do
  filename=$(basename "$expected_file")
  actual_file="$ACTUAL_DIR/$filename"

  echo "Validating: $filename"

  # Check file exists
  if [[ ! -f "$actual_file" ]]; then
    log_error "Missing file: $filename"
    continue
  fi

  # Get file info
  expected_size=$(stat -c%s "$expected_file" 2>/dev/null || stat -f%z "$expected_file")
  actual_size=$(stat -c%s "$actual_file" 2>/dev/null || stat -f%z "$actual_file")
  expected_hash=$(sha256sum "$expected_file" | awk '{print $1}')
  actual_hash=$(sha256sum "$actual_file" | awk '{print $1}')
  actual_type=$(file -b "$actual_file")

  # Compare sizes
  if [[ "$expected_size" != "$actual_size" ]]; then
    size_diff=$((actual_size - expected_size))
    size_pct=$(awk "BEGIN {printf \"%.2f\", ($size_diff / $expected_size) * 100}")
    if [[ "$STRICT" == "--strict" ]]; then
      log_error "$filename: size mismatch (expected: $expected_size, actual: $actual_size, diff: ${size_pct}%)"
    else
      log_warning "$filename: size differs by ${size_pct}% (expected: $expected_size, actual: $actual_size)"
    fi
  fi

  # Compare hashes (strict mode only fails, otherwise warns)
  if [[ "$expected_hash" != "$actual_hash" ]]; then
    if [[ "$STRICT" == "--strict" ]]; then
      log_error "$filename: SHA256 mismatch"
      echo "  Expected: $expected_hash"
      echo "  Actual:   $actual_hash"
    else
      log_warning "$filename: SHA256 differs (binaries not byte-identical, but may still be functionally equivalent)"
    fi
  else
    log_info "$filename: SHA256 match ✓"
  fi

  # Verify expected architectures based on filename
  # (We don't compare full file output since BuildID, section counts, etc. differ between builds)
  arch_ok=true
  case "$filename" in
    *linux-x64*)
      if [[ ! "$actual_type" =~ "ELF 64-bit".*"x86-64" ]]; then
        log_error "$filename: expected ELF x86-64, got: $actual_type"
        arch_ok=false
      fi
      ;;
    *linux-arm64*)
      if [[ ! "$actual_type" =~ "ELF 64-bit".*"ARM aarch64" ]]; then
        log_error "$filename: expected ELF ARM aarch64, got: $actual_type"
        arch_ok=false
      fi
      ;;
    *darwin-x64*)
      if [[ ! "$actual_type" =~ "Mach-O".*"x86_64" ]]; then
        log_error "$filename: expected Mach-O x86_64, got: $actual_type"
        arch_ok=false
      fi
      ;;
    *darwin-arm64*)
      if [[ ! "$actual_type" =~ "Mach-O".*"arm64" ]]; then
        log_error "$filename: expected Mach-O arm64, got: $actual_type"
        arch_ok=false
      fi
      ;;
    *win32-x64*.exe)
      if [[ ! "$actual_type" =~ "PE32+".*"x86-64" ]]; then
        log_error "$filename: expected PE32+ x86-64, got: $actual_type"
        arch_ok=false
      fi
      ;;
    *win32-arm64*.exe)
      if [[ ! "$actual_type" =~ "PE32+".*"Aarch64" ]]; then
        log_error "$filename: expected PE32+ Aarch64, got: $actual_type"
        arch_ok=false
      fi
      ;;
  esac

  if [[ "$arch_ok" == "true" ]]; then
    echo "  Architecture: $actual_type ✓"
  fi

  echo ""
done

# Check for extra files in actual that aren't in expected
ACTUAL_FILES=$(find "$ACTUAL_DIR" -type f -name "*" | sort)
for actual_file in $ACTUAL_FILES; do
  filename=$(basename "$actual_file")
  expected_file="$EXPECTED_DIR/$filename"
  if [[ ! -f "$expected_file" ]]; then
    log_warning "Extra file in actual: $filename"
  fi
done

# Summary
echo ""
echo "=== Validation Summary ==="
echo "Errors: ${#ERRORS[@]}"
echo "Warnings: ${#WARNINGS[@]}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "Errors:"
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  exit 1
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo ""
  echo "Warnings:"
  for warn in "${WARNINGS[@]}"; do
    echo "  - $warn"
  done
fi

echo ""
echo "✓ Validation passed"
