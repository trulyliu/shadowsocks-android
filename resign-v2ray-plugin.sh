#!/usr/bin/env bash
#
# Re-sign v2ray-plugin APKs with the cntv keystore so they share a signing
# identity with the cntv host app (com.github.skcoswodahs.tv). Without this,
# the host shows an "untrusted plugin" Snackbar (PluginManager.kt + ResolvedPlugin.kt)
# even though the plugin still loads.
#
# Usage:
#   ./resign-v2ray-plugin.sh                      # ./v2ray  -> ./v2ray/resigned
#   ./resign-v2ray-plugin.sh path/to/apks         # custom input dir
#   ./resign-v2ray-plugin.sh path/to/apks out_dir # custom in + out
#
# Credentials (env wins over gradle.properties):
#   CNTV_KEYSTORE_FILE      (default: ~/keystores/cntv-release.keystore)
#   CNTV_KEYSTORE_PASSWORD  (required)
#   CNTV_KEY_ALIAS          (default: cntv)
#   CNTV_KEY_PASSWORD       (default: same as CNTV_KEYSTORE_PASSWORD)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

IN_DIR="${1:-./v2ray}"
OUT_DIR="${2:-$IN_DIR/resigned}"
EXPECTED_SHA256="4bbdb388fdd6c5df6424e575ce21ea3faf84ecfa145f0e8d75f54fa98c86f029"

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "--- $*"; }

# --- Resolve apksigner from $ANDROID_HOME or common SDK path. ----------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
[ -d "$SDK/build-tools" ] || fail "Android SDK build-tools not found under $SDK"
BT="$(ls -1d "$SDK"/build-tools/*/ | sort -V | tail -1)"
APKSIGNER="$BT/apksigner"
[ -x "$APKSIGNER" ] || fail "apksigner not executable at $APKSIGNER"

# --- Resolve credentials. ----------------------------------------------------
KEYSTORE="${CNTV_KEYSTORE_FILE:-$HOME/keystores/cntv-release.keystore}"
KEY_ALIAS="${CNTV_KEY_ALIAS:-}"
STORE_PASS="${CNTV_KEYSTORE_PASSWORD:-}"
KEY_PASS="${CNTV_KEY_PASSWORD:-}"

# Fall back to ~/.gradle/gradle.properties for any unset value.
GP="$HOME/.gradle/gradle.properties"
prop() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$GP" 2>/dev/null || true; }
if [ -f "$GP" ]; then
    [ -z "$KEY_ALIAS"   ] && KEY_ALIAS="$(prop CNTV_KEY_ALIAS)"
    [ -z "$STORE_PASS"  ] && STORE_PASS="$(prop CNTV_KEYSTORE_PASSWORD)"
    [ -z "$KEY_PASS"    ] && KEY_PASS="$(prop CNTV_KEY_PASSWORD)"
fi
[ -z "$KEY_ALIAS"  ] && KEY_ALIAS="cntv"
[ -z "$KEY_PASS"   ] && KEY_PASS="$STORE_PASS"

[ -f "$KEYSTORE" ]    || fail "keystore missing: $KEYSTORE"
[ -n "$STORE_PASS" ]  || fail "CNTV_KEYSTORE_PASSWORD not set in env or $GP"
[ -d "$IN_DIR" ]      || fail "input dir does not exist: $IN_DIR"

# --- Collect inputs (top-level *.apk only, skip the resigned/ subdir). -------
shopt -s nullglob
inputs=()
for f in "$IN_DIR"/*.apk; do inputs+=("$f"); done
shopt -u nullglob
[ "${#inputs[@]}" -gt 0 ] || fail "no .apk files found in $IN_DIR"

mkdir -p "$OUT_DIR"

cert_sha256() {
    "$APKSIGNER" verify --print-certs "$1" 2>/dev/null \
        | awk '/SHA-256 digest:/ {print $NF; exit}'
}

# --- Re-sign loop. -----------------------------------------------------------
declare -a results=()
for apk in "${inputs[@]}"; do
    base="$(basename "$apk")"
    out="$OUT_DIR/$base"
    info "Resigning $base"

    orig_sha="$(cert_sha256 "$apk" 2>/dev/null || echo 'unsigned/unknown')"
    info "  original SHA-256: ${orig_sha:-unsigned/unknown}"

    cp -f "$apk" "$out"
    "$APKSIGNER" sign \
        --ks "$KEYSTORE" \
        --ks-key-alias "$KEY_ALIAS" \
        --ks-pass "pass:$STORE_PASS" \
        --key-pass "pass:$KEY_PASS" \
        "$out"

    new_sha="$(cert_sha256 "$out")"
    info "  new SHA-256:      $new_sha"

    if [ "$new_sha" != "$EXPECTED_SHA256" ]; then
        fail "cert fingerprint mismatch for $out (got $new_sha, expected $EXPECTED_SHA256)"
    fi

    results+=("$base|$orig_sha|$new_sha|$(stat -c%s "$out")")
done

# --- Summary. ----------------------------------------------------------------
echo
echo "============================================================"
echo "  Re-signed ${#results[@]} APK(s) into $OUT_DIR/"
echo "  All match cntv cert SHA-256: $EXPECTED_SHA256"
echo "============================================================"
for r in "${results[@]}"; do
    IFS='|' read -r name orig new size <<< "$r"
    printf "  %-40s  %s bytes\n" "$name" "$size"
done
