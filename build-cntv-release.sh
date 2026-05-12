#!/usr/bin/env bash
#
# Build a signed cntv release APK.
#
# Usage:
#   ./build-cntv-release.sh                # default ABI = arm64
#   ./build-cntv-release.sh arm64          # specific ABI
#   ./build-cntv-release.sh all            # all ABIs (slow)
#
# Credentials are read from gradle.properties or these env vars:
#   CNTV_KEYSTORE_FILE      (default: ~/keystores/cntv-release.keystore)
#   CNTV_KEYSTORE_PASSWORD  (required)
#   CNTV_KEY_ALIAS          (default: cntv)
#   CNTV_KEY_PASSWORD       (default: same as CNTV_KEYSTORE_PASSWORD; PKCS12 forces equal)
#
# applicationId override (when the default package name gets blocklisted):
#   CNTV_APPLICATION_ID     (default: com.github.skcoswodahs.tv)
#   e.g. CNTV_APPLICATION_ID=com.example.toolbox.tv ./build-cntv-release.sh arm64
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ABI="${1:-arm64}"
KEYSTORE="${CNTV_KEYSTORE_FILE:-$HOME/keystores/cntv-release.keystore}"
EXPECTED_APP_ID="${CNTV_APPLICATION_ID:-com.github.skcoswodahs.tv}"

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "--- $*"; }

# Resolve aapt2 / apksigner from $ANDROID_HOME or common SDK path.
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
[ -d "$SDK/build-tools" ] || fail "Android SDK build-tools not found under $SDK"
BT="$(ls -1d "$SDK"/build-tools/*/ | sort -V | tail -1)"
AAPT2="$BT/aapt2"
APKSIGNER="$BT/apksigner"
[ -x "$AAPT2" ] || fail "aapt2 not executable at $AAPT2"
[ -x "$APKSIGNER" ] || fail "apksigner not executable at $APKSIGNER"

info "Prerequisite check"
[ -f "$KEYSTORE" ] || fail "keystore missing: $KEYSTORE  (set CNTV_KEYSTORE_FILE or place file)"
# Smoke-test that we can read gradle properties; fall through to env if absent.
if ! grep -q '^CNTV_KEYSTORE_PASSWORD=' "$HOME/.gradle/gradle.properties" 2>/dev/null; then
    [ -n "${CNTV_KEYSTORE_PASSWORD:-}" ] || fail "CNTV_KEYSTORE_PASSWORD not in ~/.gradle/gradle.properties or env"
fi

# Build args.
GRADLE_ARGS=()
case "$ABI" in
    all|"")    info "Building cntv release for ALL ABIs (slow)";;
    arm|arm64|x86|x86_64) info "Building cntv release for ABI=$ABI"
                          GRADLE_ARGS+=("-PTARGET_ABI=$ABI");;
    *) fail "Unknown ABI '$ABI' (expected: arm | arm64 | x86 | x86_64 | all)";;
esac

# Forward applicationId override only when the env var is set, so the gradle
# default ("com.github.skcoswodahs.tv") still applies for unset builds.
if [ -n "${CNTV_APPLICATION_ID:-}" ]; then
    info "applicationId override: $CNTV_APPLICATION_ID"
    GRADLE_ARGS+=("-PCNTV_APPLICATION_ID=$CNTV_APPLICATION_ID")
fi

info "Running ./gradlew :tv:assembleCntvRelease ${GRADLE_ARGS[*]:-}"
./gradlew :tv:assembleCntvRelease "${GRADLE_ARGS[@]}"

info "Verifying outputs"
OUT_DIR="tv/build/outputs/apk/cntv/release"
[ -d "$OUT_DIR" ] || fail "expected output dir not found: $OUT_DIR"

# Pick one APK to verify in detail. Prefer the requested ABI, else any.
case "$ABI" in
    arm)    APK="$OUT_DIR/tv-cntv-armeabi-v7a-release.apk";;
    arm64)  APK="$OUT_DIR/tv-cntv-arm64-v8a-release.apk";;
    x86)    APK="$OUT_DIR/tv-cntv-x86-release.apk";;
    x86_64) APK="$OUT_DIR/tv-cntv-x86_64-release.apk";;
    *)      APK="$(ls -1 "$OUT_DIR"/tv-cntv-*-release.apk | head -1)";;
esac
[ -f "$APK" ] || fail "verification APK not produced: $APK"

info "  APK: $APK"
info "  Identity:"
"$AAPT2" dump badging "$APK" 2>/dev/null \
    | grep -E "^package:|^application-label:" \
    | sed 's/^/      /'

info "  Signature:"
"$APKSIGNER" verify --print-certs "$APK" 2>&1 \
    | grep -E "DN:|SHA-256 digest:" \
    | sed 's/^/      /'

# Sanity check: applicationId must match.
ACTUAL_APP_ID=$("$AAPT2" dump badging "$APK" | awk -F"'" '/^package:/{print $2; exit}')
if [ "$ACTUAL_APP_ID" != "$EXPECTED_APP_ID" ]; then
    fail "applicationId mismatch: got '$ACTUAL_APP_ID', expected '$EXPECTED_APP_ID'"
fi

echo
echo "========================================"
echo "  cntv release build OK"
echo "  APK(s) in: $OUT_DIR/"
echo "========================================"
ls -lh "$OUT_DIR"/*.apk | sed 's/^/  /'
