#!/usr/bin/env bash
set -euo pipefail

# Resolve script and workspace paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${SCRIPT_DIR}/.tmp"
LOG_FILE="${SCRIPT_DIR}/log.txt"
OUTPUT_DMG="${SCRIPT_DIR}/CodexAppMacIntel.dmg"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${TMP_BASE}/codex_intel_build_${RUN_ID}"
MOUNT_POINT="${WORK_DIR}/mount"

# Runtime flags/state used by cleanup and mount logic.
ATTACHED_BY_SCRIPT=0
SOURCE_APP=""

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(timestamp)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./build-intel.sh [path/to/Codex.dmg]

Behavior:
  - Reads source DMG from ../Codex.dmg by default (or explicit path argument)
  - Never modifies the original DMG
  - Uses .tmp/* for all build steps
  - Writes full logs to log.txt
  - Produces CodexAppMacIntel.dmg
EOF
}

cleanup() {
  local exit_code=$?

  # Detach only if this script mounted the DMG itself.
  if [[ "${ATTACHED_BY_SCRIPT}" -eq 1 && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    log "Build failed. See ${LOG_FILE}"
    log "Temporary files kept at: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

# Prepare log file and mirror output to console + log.txt.
mkdir -p "${TMP_BASE}"
: > "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log "Starting Intel build pipeline"
log "Script dir: ${SCRIPT_DIR}"
log "Default source location: ${SCRIPT_PARENT_DIR}/Codex.dmg"
log "Work dir: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Validate required tools early.
for cmd in hdiutil ditto npm npx node file codesign xattr; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
done

if [[ $# -gt 0 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage
  die "Too many arguments"
fi

# Resolve source DMG path:
# 1) explicit argument
# 2) ../Codex.dmg
# 3) single *.dmg in parent directory (if present)
if [[ $# -eq 1 ]]; then
  INPUT_DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  if [[ -f "${SCRIPT_PARENT_DIR}/Codex.dmg" ]]; then
    INPUT_DMG="${SCRIPT_PARENT_DIR}/Codex.dmg"
  else
    mapfile -t found_dmgs < <(find "${SCRIPT_PARENT_DIR}" -maxdepth 1 -type f -name "*.dmg" ! -name "$(basename "${OUTPUT_DMG}")" | sort)
    if [[ ${#found_dmgs[@]} -eq 0 ]]; then
      die "No source DMG found. Put Codex.dmg next to this repo folder (../Codex.dmg) or pass a path."
    fi
    if [[ ${#found_dmgs[@]} -gt 1 ]]; then
      printf '%s\n' "${found_dmgs[@]}"
      die "Multiple DMGs found. Pass source DMG path explicitly."
    fi
    INPUT_DMG="${found_dmgs[0]}"
  fi
fi

[[ -f "${INPUT_DMG}" ]] || die "Source DMG not found: ${INPUT_DMG}"
log "Source DMG: ${INPUT_DMG}"

# Mount source DMG in read-only mode.
log "Mounting source DMG in read-only mode"
mkdir -p "${MOUNT_POINT}"
if hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${INPUT_DMG}" >/dev/null; then
  ATTACHED_BY_SCRIPT=1
  SOURCE_APP="${MOUNT_POINT}/Codex.app"
else
  if [[ -d "/Volumes/Codex Installer/Codex.app" ]]; then
    SOURCE_APP="/Volumes/Codex Installer/Codex.app"
    log "Using existing mounted volume: ${SOURCE_APP}"
  else
    die "Failed to mount DMG and no fallback mounted Codex.app found"
  fi
fi
[[ -d "${SOURCE_APP}" ]] || die "Codex.app not found inside DMG"

ORIG_APP="${WORK_DIR}/CodexOriginal.app"
TARGET_APP="${WORK_DIR}/Codex.app"
BUILD_PROJECT="${WORK_DIR}/build-project"
DMG_ROOT="${WORK_DIR}/dmg-root"

# Copy app bundle from mounted DMG to local writable work dir.
log "Copying source app bundle to work dir"
ditto "${SOURCE_APP}" "${ORIG_APP}"

FRAMEWORK_INFO="${ORIG_APP}/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
[[ -f "${FRAMEWORK_INFO}" ]] || die "Cannot read Electron framework info plist"
ELECTRON_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${FRAMEWORK_INFO}" 2>/dev/null || true)"
[[ -n "${ELECTRON_VERSION}" ]] || die "Cannot detect Electron version from source app"

ASAR_FILE="${ORIG_APP}/Contents/Resources/app.asar"
[[ -f "${ASAR_FILE}" ]] || die "app.asar not found in source app"

# Read dependency versions from app.asar metadata.
ASAR_META_DIR="${WORK_DIR}/asar-meta"
mkdir -p "${ASAR_META_DIR}"
(
  cd "${ASAR_META_DIR}"
  npx --yes @electron/asar extract-file "${ASAR_FILE}" "node_modules/better-sqlite3/package.json"
  mv package.json better-sqlite3.package.json
  npx --yes @electron/asar extract-file "${ASAR_FILE}" "node_modules/node-pty/package.json"
  mv package.json node-pty.package.json
)

BS_PKG="${ASAR_META_DIR}/better-sqlite3.package.json"
NP_PKG="${ASAR_META_DIR}/node-pty.package.json"
[[ -f "${BS_PKG}" ]] || die "Cannot extract better-sqlite3 package.json from app.asar"
[[ -f "${NP_PKG}" ]] || die "Cannot extract node-pty package.json from app.asar"
BS_VERSION="$(node -p "require(process.argv[1]).version" "${BS_PKG}")"
NP_VERSION="$(node -p "require(process.argv[1]).version" "${NP_PKG}")"

log "Detected Electron version: ${ELECTRON_VERSION}"
log "Detected better-sqlite3 version: ${BS_VERSION}"
log "Detected node-pty version: ${NP_VERSION}"

# Build a temporary project to fetch x64 Electron/runtime artifacts.
log "Preparing x64 build project"
mkdir -p "${BUILD_PROJECT}"
cat > "${BUILD_PROJECT}/package.json" <<EOF
{
  "name": "codex-intel-rebuild",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "@openai/codex": "latest",
    "better-sqlite3": "${BS_VERSION}",
    "electron": "${ELECTRON_VERSION}",
    "node-pty": "${NP_VERSION}"
  },
  "devDependencies": {
    "@electron/rebuild": "3.7.2"
  }
}
EOF

(
  cd "${BUILD_PROJECT}"
  npm install --no-audit --no-fund
)

# Use Electron x64 app template as the destination runtime.
log "Creating Intel app bundle from Electron runtime"
ditto "${BUILD_PROJECT}/node_modules/electron/dist/Electron.app" "${TARGET_APP}"

# Inject original Codex app resources into the x64 runtime shell.
log "Injecting Codex resources from original app"
rm -rf "${TARGET_APP}/Contents/Resources"
ditto "${ORIG_APP}/Contents/Resources" "${TARGET_APP}/Contents/Resources"
cp "${ORIG_APP}/Contents/Info.plist" "${TARGET_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Electron" "${TARGET_APP}/Contents/Info.plist" >/dev/null
# Codex main process treats isPackaged=false as dev and tries localhost:5175.
# Force renderer URL to bundled app protocol in this transplanted runtime.
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:ELECTRON_RENDERER_URL string app://-/index.html" "${TARGET_APP}/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:ELECTRON_RENDERER_URL app://-/index.html" "${TARGET_APP}/Contents/Info.plist" >/dev/null

# Rebuild native modules against Electron x64 ABI.
log "Rebuilding native modules for Electron ${ELECTRON_VERSION} x64"
(
  cd "${BUILD_PROJECT}"
  npx --yes @electron/rebuild -f -w better-sqlite3,node-pty --arch=x64 --version "${ELECTRON_VERSION}" -m "${BUILD_PROJECT}"
)

TARGET_UNPACKED="${TARGET_APP}/Contents/Resources/app.asar.unpacked"
[[ -d "${TARGET_UNPACKED}" ]] || die "Target app.asar.unpacked not found"

# Replace arm64 native artifacts with rebuilt x64 binaries.
log "Replacing native binaries inside app.asar.unpacked"
install -m 755 "${BUILD_PROJECT}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
  "${TARGET_UNPACKED}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
install -m 755 "${BUILD_PROJECT}/node_modules/node-pty/build/Release/pty.node" \
  "${TARGET_UNPACKED}/node_modules/node-pty/build/Release/pty.node"
install -m 755 "${BUILD_PROJECT}/node_modules/node-pty/build/Release/spawn-helper" \
  "${TARGET_UNPACKED}/node_modules/node-pty/build/Release/spawn-helper"

NODE_PTY_BIN_SRC="$(find "${BUILD_PROJECT}/node_modules/node-pty/bin" -type f -name "node-pty.node" | grep "darwin-x64" | head -n 1 || true)"
if [[ -n "${NODE_PTY_BIN_SRC}" ]]; then
  mkdir -p "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143"
  install -m 755 "${NODE_PTY_BIN_SRC}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143/node-pty.node"
  if [[ -f "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-arm64-143/node-pty.node" ]]; then
    # Keep hardcoded/fallback load paths functional even if the app references arm64 folder.
    install -m 755 "${NODE_PTY_BIN_SRC}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-arm64-143/node-pty.node"
  fi
fi

CLI_X64_ROOT="${BUILD_PROJECT}/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin"
CLI_X64_BIN="${CLI_X64_ROOT}/codex/codex"
RG_X64_BIN="${CLI_X64_ROOT}/path/rg"

# On arm64 hosts, npm may skip darwin-x64 optional package. Fetch tarball explicitly.
if [[ ! -f "${CLI_X64_BIN}" || ! -f "${RG_X64_BIN}" ]]; then
  log "x64 Codex CLI package not found in node_modules, trying to install @openai/codex-darwin-x64"
  CODEX_JS_PKG="${BUILD_PROJECT}/node_modules/@openai/codex/package.json"
  CODEX_VER="$(node -p "require(process.argv[1]).version" "${CODEX_JS_PKG}" 2>/dev/null || true)"
  PKG_SPEC_VERSIONED="@openai/codex-darwin-x64@${CODEX_VER:-latest}"
  PKG_SPEC_LATEST="@openai/codex-darwin-x64@latest"

  try_install_pkg() {
    local spec="$1"
    local attempts=4
    local i
    for i in $(seq 1 "${attempts}"); do
      if (cd "${BUILD_PROJECT}" && npm install --no-save --no-audit --no-fund "${spec}" >/tmp/codex_pkg_install.out 2>/tmp/codex_pkg_install.err); then
        return 0
      fi
      log "Install ${spec} failed (attempt ${i}/${attempts}), retrying..."
      sleep $((i * 2))
    done
    return 1
  }

  if ! try_install_pkg "${PKG_SPEC_VERSIONED}"; then
    log "Failed to install ${PKG_SPEC_VERSIONED}, trying ${PKG_SPEC_LATEST}"
    try_install_pkg "${PKG_SPEC_LATEST}" || true
  fi

  CLI_X64_ROOT="${BUILD_PROJECT}/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin"
  CLI_X64_BIN="${CLI_X64_ROOT}/codex/codex"
  RG_X64_BIN="${CLI_X64_ROOT}/path/rg"

  # Final fallback for cases where install is blocked but tarball download still works.
  if [[ ! -f "${CLI_X64_BIN}" || ! -f "${RG_X64_BIN}" ]]; then
    log "Direct install still missing x64 CLI package, trying npm pack fallback"
    PKG_DIR="${WORK_DIR}/codex-darwin-x64-package"
    mkdir -p "${PKG_DIR}"
    (
      cd "${PKG_DIR}"
      if ! npm pack --silent "${PKG_SPEC_VERSIONED}" >/tmp/codex_pack_name.txt 2>/tmp/codex_pack_err.txt; then
        log "Failed to pack ${PKG_SPEC_VERSIONED}, falling back to ${PKG_SPEC_LATEST}"
        npm pack --silent "${PKG_SPEC_LATEST}" >/tmp/codex_pack_name.txt
      fi
      PKG_TGZ="$(tail -n 1 /tmp/codex_pack_name.txt)"
      tar -xzf "${PKG_TGZ}"
    )
    CLI_X64_ROOT="${PKG_DIR}/package/vendor/x86_64-apple-darwin"
    CLI_X64_BIN="${CLI_X64_ROOT}/codex/codex"
    RG_X64_BIN="${CLI_X64_ROOT}/path/rg"
  fi
fi

[[ -f "${CLI_X64_BIN}" ]] || die "x64 Codex CLI binary not found after install/pack fallback (possible npm registry outage or package publish mismatch)"
[[ -f "${RG_X64_BIN}" ]] || die "x64 rg binary not found after install/pack fallback (possible npm registry outage or package publish mismatch)"

# Replace bundled arm64 codex/rg command-line binaries.
log "Replacing bundled codex/rg binaries with x64 versions"
install -m 755 "${CLI_X64_BIN}" "${TARGET_APP}/Contents/Resources/codex"
install -m 755 "${CLI_X64_BIN}" "${TARGET_APP}/Contents/Resources/app.asar.unpacked/codex"
install -m 755 "${RG_X64_BIN}" "${TARGET_APP}/Contents/Resources/rg"

# Sparkle native addon is arm64-only in this flow; disable it.
log "Disabling incompatible Sparkle native addon"
rm -f "${TARGET_APP}/Contents/Resources/native/sparkle.node"
rm -f "${TARGET_APP}/Contents/Resources/app.asar.unpacked/native/sparkle.node"

# Sanity-check key binaries before signing/packaging.
log "Validating key binaries are x86_64"
for binary in \
  "${TARGET_APP}/Contents/MacOS/Electron" \
  "${TARGET_APP}/Contents/Resources/codex" \
  "${TARGET_APP}/Contents/Resources/rg" \
  "${TARGET_APP}/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
  "${TARGET_APP}/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"; do
  file_output="$(file "${binary}")"
  echo "${file_output}"
  [[ "${file_output}" == *"x86_64"* ]] || die "Expected x86_64 binary: ${binary}"
done

# Re-sign modified app ad-hoc to satisfy macOS code integrity checks.
log "Signing app ad-hoc"
xattr -cr "${TARGET_APP}" || true
codesign --force --deep --sign - --timestamp=none "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

# Build final distributable DMG.
log "Building output DMG: ${OUTPUT_DMG}"
rm -f "${OUTPUT_DMG}"
mkdir -p "${DMG_ROOT}"
ditto "${TARGET_APP}" "${DMG_ROOT}/Codex.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "Codex App Mac Intel" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null

log "Done"
log "Output DMG: ${OUTPUT_DMG}"
log "Build log: ${LOG_FILE}"
log "Work dir: ${WORK_DIR}"
