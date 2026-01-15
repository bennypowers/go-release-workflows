#!/usr/bin/env bash
set -euo pipefail

# Validate build outputs by comparing two artifact directories
# Usage: validate-build.sh <expected-dir> <actual-dir> [options]
# Example: validate-build.sh artifacts-old artifacts-new --size-tolerance=10 --health-check=version
#
# Options:
#   --size-tolerance=N    Max size difference % (default: 10)
#   --health-check=CMD    Command to run on native binaries (e.g., "version", "--help")
#
# Checks:
# - Architecture verification via `file` command
# - File size within tolerance
# - Health check for native binaries (if configured)
# - File existence
#
# Hash comparison intentionally omitted - different toolchains, timestamps, and
# build metadata produce different hashes for functionally equivalent binaries.

EXPECTED_DIR="$1"
ACTUAL_DIR="$2"
SIZE_TOLERANCE=10  # Default 10% tolerance
HEALTH_CHECK=""    # Optional health check command

# Parse optional arguments
shift 2
for arg in "$@"; do
  case "$arg" in
    --size-tolerance=*)
      SIZE_TOLERANCE="${arg#*=}"
      ;;
    --health-check=*)
      HEALTH_CHECK="${arg#*=}"
      ;;
  esac
done

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

# Detect current platform for functional tests
detect_platform() {
  local os arch

  # Handle Windows (MINGW/MSYS from Git Bash)
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    os="win32"
    # Check processor architecture on Windows
    case "${PROCESSOR_ARCHITECTURE:-unknown}" in
      AMD64) arch="x64" ;;
      ARM64) arch="arm64" ;;
      *) arch="x64" ;;  # Default to x64
    esac
  else
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
      linux) os="linux" ;;
      darwin) os="darwin" ;;
      *) os="unknown" ;;
    esac

    case "$arch" in
      x86_64|amd64) arch="x64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) arch="unknown" ;;
    esac
  fi

  echo "${os}-${arch}"
}

# Check if 'file' command is available (not on Windows)
has_file_command() {
  command -v file &>/dev/null
}

CURRENT_PLATFORM=$(detect_platform)
echo "Current platform: $CURRENT_PLATFORM"
echo "Size tolerance: ${SIZE_TOLERANCE}%"
if [[ -n "$HEALTH_CHECK" ]]; then
  echo "Health check: $HEALTH_CHECK"
fi
echo ""

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

  # Get file sizes (cross-platform)
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    # Windows (Git Bash) - use wc -c
    expected_size=$(wc -c < "$expected_file" | tr -d ' ')
    actual_size=$(wc -c < "$actual_file" | tr -d ' ')
  else
    expected_size=$(stat -c%s "$expected_file" 2>/dev/null || stat -f%z "$expected_file")
    actual_size=$(stat -c%s "$actual_file" 2>/dev/null || stat -f%z "$actual_file")
  fi

  # Get file type (if available)
  if has_file_command; then
    actual_type=$(file -b "$actual_file")
  else
    actual_type="(file command not available)"
  fi

  # Compare sizes with tolerance
  if [[ "$expected_size" != "$actual_size" ]]; then
    size_diff=$((actual_size - expected_size))
    # Use absolute value for percentage
    if [[ $size_diff -lt 0 ]]; then
      size_diff=$((-size_diff))
    fi
    size_pct=$(awk "BEGIN {printf \"%.2f\", ($size_diff / $expected_size) * 100}")
    size_pct_int=${size_pct%.*}

    if [[ $size_pct_int -gt $SIZE_TOLERANCE ]]; then
      log_error "$filename: size differs by ${size_pct}% (exceeds ${SIZE_TOLERANCE}% tolerance)"
      echo "  Expected: $expected_size bytes"
      echo "  Actual:   $actual_size bytes"
    else
      echo "  Size: $actual_size bytes (${size_pct}% difference, within tolerance)"
    fi
  else
    echo "  Size: $actual_size bytes (exact match)"
  fi

  # Verify expected architectures based on filename (requires 'file' command)
  arch_ok=true
  if has_file_command; then
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
  else
    echo "  Architecture: (skipped - 'file' command not available)"
  fi

  # Health check for native binaries (if configured)
  if [[ -n "$HEALTH_CHECK" && "$arch_ok" == "true" ]]; then
    is_native=false
    case "$filename" in
      *"$CURRENT_PLATFORM"*)
        is_native=true
        ;;
    esac

    if [[ "$is_native" == "true" ]]; then
      # Make executable (not needed on Windows but doesn't hurt)
      chmod +x "$actual_file" 2>/dev/null || true
      echo "  Running health check: $actual_file $HEALTH_CHECK"

      # shellcheck disable=SC2086 # Intentional word splitting for multi-arg commands
      if output=$("$actual_file" $HEALTH_CHECK 2>&1); then
        # Truncate output for display
        output_display="${output:0:100}"
        if [[ ${#output} -gt 100 ]]; then
          output_display="${output_display}..."
        fi
        echo "  Health check: ✓"
        echo "    Output: $output_display"
      else
        exit_code=$?
        log_error "$filename: health check failed (exit code $exit_code)"
        echo "    Output: ${output:0:200}"
      fi
    fi
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
