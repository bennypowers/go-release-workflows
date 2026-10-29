#!/usr/bin/env bash
# Shared helpers for the shell test suites.
# Sourced by test/*.sh; not run directly.

PASS=0
FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  PASS=$((PASS + 1))
}

# init_case <workdir> <name>
# Creates the per-case directory and sets DIR.
init_case() {
  local work="$1" name="$2"
  DIR="$work/$name"
  mkdir -p "$DIR"
}
