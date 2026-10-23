#!/bin/bash
# Audit every place a release version string is mirrored.
#
# Sources compared (repo-root VERSION is the authority for the app version,
# AppVersion.extensionVersion is the authority for the extension version):
#   (a) VERSION
#   (b) Sources/DownloaderCore/AppVersion.swift appVersion literal
#   (c) Sources/DownloaderCore/AppVersion.swift extensionVersion literal
#   (d) Extension/manifest.json version
#   (e) dist/Internet Downloader.app Info.plist CFBundleShortVersionString (if installed)
#   (f) extension handshake mirror (IDM_EXPECTED_APP_VERSION, else appVersion literal)
#
# Exit codes: 0 = every source agrees, 1 = a source is missing or different,
#             2 = usage error.
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR" || exit 2

usage() {
    cat <<'EOF'
Usage: bash scripts/check_versions.sh [--no-dist]

  --no-dist   skip the installed dist bundle check (use while a rollout is pending)
  -h, --help  show this help
EOF
}

CHECK_DIST=1
for arg in "$@"; do
    case "$arg" in
        --no-dist) CHECK_DIST=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

VERSION_FILE="VERSION"
APPVERSION_SWIFT="Sources/DownloaderCore/AppVersion.swift"
EXTENSION_MANIFEST="Extension/manifest.json"
DIST_APP="${IDM_DIST_APP:-dist/Internet Downloader.app}"
INFO_PLIST="$DIST_APP/Contents/Info.plist"

NAMES=()
EXPECTED=()
FOUND=()
STATUSES=()
FAIL=0

file_version() {
    [ -f "$1" ] || return 0
    tr -d '[:space:]' < "$1"
}

# Read `public static let <name> = "<value>"` from AppVersion.swift.
swift_string_literal() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    sed -n -E "s/.*static let ${name}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n 1
}

json_string() {
    [ -f "$1" ] || return 0
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
}

plist_string() {
    [ -f "$1" ] || return 0
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

record() {
    # record <source> <expected> <found>
    local source="$1" expected="$2" found="$3" status="ok"
    if [ -z "$found" ] || [ "$found" = "<missing>" ]; then
        status="MISSING"; FAIL=1
    elif [ "$expected" != "$found" ]; then
        status="MISMATCH"; FAIL=1
    fi
    NAMES+=("$source"); EXPECTED+=("$expected"); FOUND+=("${found:-<missing>}"); STATUSES+=("$status")
}

skip_row() {
    NAMES+=("$1"); EXPECTED+=("-"); FOUND+=("-"); STATUSES+=("skip")
}

APP_FROM_FILE="$(file_version "$VERSION_FILE")"
APP_FROM_SWIFT="$(swift_string_literal "$APPVERSION_SWIFT" appVersion)"
EXT_FROM_SWIFT="$(swift_string_literal "$APPVERSION_SWIFT" extensionVersion)"
EXT_FROM_MANIFEST="$(json_string "$EXTENSION_MANIFEST" version)"

APP_EXPECTED="${APP_FROM_FILE:-${APP_FROM_SWIFT:-<missing>}}"
EXT_EXPECTED="${EXT_FROM_SWIFT:-${EXT_FROM_MANIFEST:-<missing>}}"

record "VERSION" "$APP_EXPECTED" "${APP_FROM_FILE:-<missing>}"
record "Sources/DownloaderCore/AppVersion.swift appVersion" "$APP_EXPECTED" "${APP_FROM_SWIFT:-<missing>}"
record "Sources/DownloaderCore/AppVersion.swift extensionVersion" "$EXT_EXPECTED" "${EXT_FROM_SWIFT:-<missing>}"
record "Extension/manifest.json version" "$EXT_EXPECTED" "${EXT_FROM_MANIFEST:-<missing>}"

# (e) A stale installed bundle is exactly the bug this check exists to catch.
if [ "$CHECK_DIST" = "1" ]; then
    if [ -d "$DIST_APP" ]; then
        INSTALLED_VERSION="$(plist_string "$INFO_PLIST" CFBundleShortVersionString)"
        record "dist app Info.plist (installed bundle)" "$APP_EXPECTED" "${INSTALLED_VERSION:-<missing>}"
    else
        skip_row "dist app (not installed)"
    fi
fi

# (f) The extension's own handshake copy: one shared constant once refactored,
#     literal literals before that.
JS_CONST_FILE="Extension/browser-transfer.js"
JS_CONST_VERSION=""
if [ -f "$JS_CONST_FILE" ]; then
    JS_CONST_VERSION="$(sed -n -E "s/.*IDM_EXPECTED_APP_VERSION[[:space:]]*=[[:space:]]*['\"]([0-9]+\.[0-9]+\.[0-9]+)['\"].*/\1/p" "$JS_CONST_FILE" | head -n 1)"
fi
if [ -n "$JS_CONST_VERSION" ]; then
    record "Extension/browser-transfer.js IDM_EXPECTED_APP_VERSION" "$APP_EXPECTED" "$JS_CONST_VERSION"
else
    JS_LITERALS="$(grep -hoE "appVersion[^\"']*[\"'][0-9]+\.[0-9]+\.[0-9]+[\"']" Extension/background.js Extension/browser-transfer.js 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | sort -u)"
    JS_VALUES="$(printf '%s\n' "$JS_LITERALS" | sed '/^$/d')"
    JS_UNIQUE="$(printf '%s\n' "$JS_VALUES" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    case "$JS_UNIQUE" in
        0) skip_row "Extension JS appVersion mirror (not found)" ;;
        1) record "Extension JS appVersion mirror" "$APP_EXPECTED" "$(printf '%s\n' "$JS_VALUES" | head -n 1)" ;;
        *)
            NAMES+=("Extension JS appVersion mirror")
            EXPECTED+=("$APP_EXPECTED")
            FOUND+=("$(printf '%s\n' "$JS_VALUES" | tr '\n' ' ' | sed 's/ $//')")
            STATUSES+=("CONFLICT")
            FAIL=1
            ;;
    esac
fi

# --- Report ---------------------------------------------------------------
WIDTH=9
for name in "${NAMES[@]}"; do
    [ "${#name}" -gt "$WIDTH" ] && WIDTH="${#name}"
done
printf "%-${WIDTH}s  %-10s  %-10s  %s\n" "SOURCE" "EXPECTED" "FOUND" "STATUS"
printf '%*s\n' "$((WIDTH + 40))" '' | tr ' ' '-'
for i in "${!NAMES[@]}"; do
    printf "%-${WIDTH}s  %-10s  %-10s  %s\n" "${NAMES[$i]}" "${EXPECTED[$i]}" "${FOUND[$i]}" "${STATUSES[$i]}"
done

echo
if [ "$FAIL" -eq 0 ]; then
    echo "OK: app version $APP_EXPECTED and extension version $EXT_EXPECTED agree across all sources."
    exit 0
fi
echo "FAIL: version sources disagree. Fix before releasing:"
for i in "${!NAMES[@]}"; do
    case "${STATUSES[$i]}" in
        MISSING|MISMATCH|CONFLICT)
            echo "  - ${NAMES[$i]}: expected ${EXPECTED[$i]}, found ${FOUND[$i]} (${STATUSES[$i]})"
            ;;
    esac
done
echo
echo "Single source of truth: repo-root VERSION -> Sources/DownloaderCore/AppVersion.swift -> Extension/manifest.json."
echo "After fixing, rebuild + reinstall: bash scripts/build_app.sh, then python3 scripts/install_release.py --stage <stage>."
echo "Use --no-dist to audit only the source files before the dist bundle is rebuilt."
exit 1
