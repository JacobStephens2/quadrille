#!/usr/bin/env bash
# Print the version for this release run.
# A tag is accepted only when its version is numbers separated by dots,
# for example 1.2.0. Any other ref is a manual dry-run named from the commit SHA.
set -euo pipefail

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  version="${GITHUB_REF_NAME:-}"
  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    echo "::error::Release tag must be numbers separated by dots, for example v1.2.0" >&2
    exit 1
  fi
  printf '%s\n' "$version"
  exit 0
fi

sha="${GITHUB_SHA:-}"
printf 'dev-%s\n' "${sha:0:7}"
