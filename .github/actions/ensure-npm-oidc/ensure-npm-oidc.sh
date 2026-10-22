#!/usr/bin/env bash
set -euo pipefail

# Trusted publishing (OIDC authentication without NPM_TOKEN) needs npm >= 11.5.1.
# npm versions before that have no OIDC exchange code and fail with ENEEDAUTH.
# Pin an 11.x range instead of @latest: npm 12 requires Node ^22.22.2 ||
# ^24.15.0 || >=26 and fails with EBADENGINE on older Node 24 minors.

minimum="${MINIMUM_VERSION:-11.5.1}"
install="${INSTALL_VERSION:-^11.19.1}"

current="$(npm --version)"
IFS=. read -r cur_major cur_minor _ <<< "$current"
IFS=. read -r min_major min_minor _ <<< "$minimum"

too_old() {
  (( $1 < $3 || ($1 == $3 && $2 < $4) ))
}

if too_old "$cur_major" "$cur_minor" "$min_major" "$min_minor"; then
  echo "npm ${current} is too old for OIDC trusted publishing (minimum ${minimum})"
  echo "Installing npm@${install}"
  npm install -g "npm@${install}"
  current="$(npm --version)"
  IFS=. read -r cur_major cur_minor _ <<< "$current"
  if too_old "$cur_major" "$cur_minor" "$min_major" "$min_minor"; then
    echo "::error::npm ${current} is still below ${minimum} after install"
    exit 1
  fi
fi

echo "npm ${current} supports OIDC trusted publishing"
