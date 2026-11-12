#!/usr/bin/env bash
# Fail unless the APK signer certificate SHA-256 equals UPLOAD_CERT_SHA256.
# The expected fingerprint is an input. This script does not read a keystore.
set -euo pipefail

normalize() {
  printf '%s' "$1" | tr -d '[:space:]' | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

expected="$(normalize "${UPLOAD_CERT_SHA256:-}")"
if [[ -z "$expected" ]]; then
  echo "::error::Upload certificate fingerprint secret is missing" >&2
  exit 1
fi

apk="${APK_PATH:-}"
if [[ -z "$apk" || ! -f "$apk" ]]; then
  echo "::error::Staged APK path is missing" >&2
  exit 1
fi

android_home="${ANDROID_HOME:-}"
if [[ -z "$android_home" ]]; then
  echo "::error::ANDROID_HOME is unset" >&2
  exit 1
fi

shopt -s nullglob
candidates=("$android_home"/build-tools/*/apksigner)
shopt -u nullglob
if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "::error::apksigner was not found under ANDROID_HOME" >&2
  exit 1
fi
apksigner="$(printf '%s\n' "${candidates[@]}" | sort -V | tail -1)"

if ! certs="$("$apksigner" verify --print-certs "$apk")"; then
  echo "::error::APK signature verification failed" >&2
  exit 1
fi
printf '%s\n' "$certs"

found=0
while IFS= read -r line; do
  if [[ "$line" == *"certificate SHA-256 digest:"* ]]; then
    found=1
    actual="$(normalize "${line#*certificate SHA-256 digest:}")"
    if [[ "$actual" != "$expected" ]]; then
      echo "::error::APK signer certificate SHA-256 does not match the upload certificate" >&2
      exit 1
    fi
  fi
done <<< "$certs"

if [[ "$found" -ne 1 ]]; then
  echo "::error::APK signer certificate SHA-256 was not reported" >&2
  exit 1
fi
