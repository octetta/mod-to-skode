#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION_FILE="${ROOT_DIR}/SKRED_VERSION"
TARGET_DIR="${ROOT_DIR}/vendor/skred"
PUBLIC_DIR="${ROOT_DIR}/public/vendor/skred"

mkdir -p "${TARGET_DIR}"
mkdir -p "${PUBLIC_DIR}"

VERSION="${1:-${VERSION:-}}"

if [ -z "${VERSION}" ]; then
  echo "==> Checking latest release on github.com/octetta/pulp..."
  LATEST_TAG=$(curl -s "https://api.github.com/repos/octetta/pulp/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [ -n "${LATEST_TAG}" ]; then
    VERSION="${LATEST_TAG#v}"
    echo "==> Detected latest release: v${VERSION}"
  elif [ -f "${VERSION_FILE}" ]; then
    VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
    echo "==> Using pinned version from SKRED_VERSION: ${VERSION}"
  else
    VERSION="0.80.0"
  fi
fi

# Strip leading 'v' if supplied (e.g. v0.80.0 -> 0.80.0)
VERSION="${VERSION#v}"

echo "==> Fetching Skred WASM assets for v${VERSION} from github.com/octetta/pulp..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_NAME="skred-${VERSION}-maxed-wasm.zip"
DOWNLOAD_URL="https://github.com/octetta/pulp/releases/download/v${VERSION}/${ARCHIVE_NAME}"

echo "Downloading ${DOWNLOAD_URL}..."
if curl -fSL --progress-bar "${DOWNLOAD_URL}" -o "${TMP_DIR}/${ARCHIVE_NAME}"; then
  echo "Extracting ${ARCHIVE_NAME}..."
  unzip -q -o "${TMP_DIR}/${ARCHIVE_NAME}" -d "${TMP_DIR}/extracted"

  find "${TMP_DIR}/extracted" -type f -name "skred_api.*" -exec cp -f {} "${TARGET_DIR}/" \;
  find "${TMP_DIR}/extracted" -type f -name "skred_api.*" -exec cp -f {} "${PUBLIC_DIR}/" \;

  echo "${VERSION}" > "${VERSION_FILE}"
  echo "==> Successfully installed Skred v${VERSION} into vendor/skred/ and public/vendor/skred/:"
  ls -lh "${TARGET_DIR}"
else
  echo "Error: Failed to download ${DOWNLOAD_URL}" >&2
  echo "Check if release v${VERSION} and asset ${ARCHIVE_NAME} exist at https://github.com/octetta/pulp/releases" >&2
  exit 1
fi
