#!/usr/bin/env bash
#
# Android TV emulator helper for cntv testing.
#
# Subcommands:
#   setup      Download API 34 TV system image + create the cntv_tv AVD.
#   boot       Start emulator in background, wait for sys.boot_completed.
#   install    Install cntv release APK + resigned v2ray plugin.
#   launch     am start the cntv MainActivity, tail relevant logcat lines.
#   up         boot && install && launch.
#   stop       adb emu kill.
#   status     Report AVD / emulator / package install state.
#
# Env overrides (rarely needed):
#   ANDROID_HOME     Android SDK (default: ~/Android/Sdk)
#   JAVA_HOME        JDK 17+ for cmdline-tools (default: /opt/android-studio/jbr)
#   EMU_FLAGS        extra args for `emulator` (e.g. "-no-window")
#
set -euo pipefail

# --- Constants ---------------------------------------------------------------
AVD_NAME="cntv_tv_api34"
# Android TV system images are published only for x86 (32-bit) and arm64-v8a;
# no x86_64 TV image exists. x86 runs near-native on x86_64 + KVM hosts.
SYSTEM_IMAGE="system-images;android-34;android-tv;x86"
SYSTEM_IMAGE_DIR="$HOME/Android/Sdk/system-images/android-34/android-tv/x86"
DEVICE_PROFILE="tv_1080p"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APK_HOST="$SCRIPT_DIR/tv/build/outputs/apk/cntv/release/tv-cntv-x86-release.apk"
APK_PLUGIN="$SCRIPT_DIR/v2ray/resigned/v2ray--universal-1.3.3.apk"
HOST_PKG="com.github.skcoswodahs.tv"
HOST_ACTIVITY="com.github.shadowsocks.tv.MainActivity"
PLUGIN_PKG="com.github.shadowsocks.plugin.v2ray"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
JBR="${JAVA_HOME_OVERRIDE:-${JAVA_HOME:-/opt/android-studio/jbr}}"
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"
EMU_LOG="/tmp/tv-emulator-${AVD_NAME}.log"

# --- Helpers -----------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "--- $*"; }

require_sdk() {
    [ -d "$SDK" ] || fail "Android SDK not found at $SDK (set ANDROID_HOME)"
    [ -x "$ADB" ] || fail "adb missing at $ADB"
    [ -x "$EMULATOR" ] || fail "emulator missing at $EMULATOR"
    [ -x "$SDKMANAGER" ] || fail "sdkmanager missing at $SDKMANAGER (install cmdline-tools)"
    [ -x "$AVDMANAGER" ] || fail "avdmanager missing at $AVDMANAGER"
    if ! "$JBR/bin/java" -version 2>&1 | grep -qE '"(1[7-9]|[2-9][0-9])\.'; then
        fail "JDK 17+ required for cmdline-tools; got: $($JBR/bin/java -version 2>&1 | head -1). Set JAVA_HOME_OVERRIDE."
    fi
}

run_jdk() { JAVA_HOME="$JBR" PATH="$JBR/bin:$PATH" "$@"; }

avd_exists()  { [ -d "$HOME/.android/avd/${AVD_NAME}.avd" ]; }
image_present() { [ -d "$SYSTEM_IMAGE_DIR" ]; }
emu_booted()  { [ "$("$ADB" -e get-state 2>/dev/null || true)" = "device" ] \
                && [ "$("$ADB" -e shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
pkg_installed() { "$ADB" -e shell pm list packages 2>/dev/null | grep -q "^package:$1\$"; }

wait_for_boot() {
    info "Waiting for emulator to finish booting (≤120s)..."
    "$ADB" wait-for-device
    local n=0
    while [ "$n" -lt 120 ]; do
        if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
            info "  Boot complete after ${n}s."
            return 0
        fi
        sleep 2; n=$((n + 2))
    done
    fail "emulator did not boot within 120s; see $EMU_LOG"
}

# --- Subcommands -------------------------------------------------------------

cmd_setup() {
    require_sdk
    [ -r /dev/kvm ] || fail "/dev/kvm not readable; user not in kvm group?"

    # Disk-space sanity.
    local free_kb avail_gb
    free_kb=$(df -k "$SDK" | awk 'NR==2 {print $4}')
    avail_gb=$((free_kb / 1024 / 1024))
    if [ "$avail_gb" -lt 3 ]; then
        fail "only ${avail_gb}G free on $(df -h "$SDK" | awk 'NR==2 {print $6}') — need ≥3G for system image + AVD"
    fi
    info "Disk free: ${avail_gb}G (OK)"

    if image_present; then
        info "System image already present: $SYSTEM_IMAGE"
    else
        info "Accepting SDK licenses..."
        # `yes |` triggers SIGPIPE under `set -o pipefail`; suppress for these two.
        set +o pipefail
        yes | run_jdk "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
        set -o pipefail

        info "Downloading $SYSTEM_IMAGE (~1.5 GB) — this may take several minutes..."
        run_jdk "$SDKMANAGER" "$SYSTEM_IMAGE"
        image_present || fail "system image download did not produce expected dir"
    fi

    if avd_exists; then
        info "AVD '$AVD_NAME' already exists at $HOME/.android/avd/$AVD_NAME.avd"
    else
        info "Creating AVD '$AVD_NAME' (device=$DEVICE_PROFILE)..."
        echo "no" | run_jdk "$AVDMANAGER" create avd \
            --force \
            --name "$AVD_NAME" \
            --package "$SYSTEM_IMAGE" \
            --device "$DEVICE_PROFILE"

        # Tweak config: disable boot anim, enable hw keyboard for test.
        local cfg="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
        if [ -f "$cfg" ]; then
            grep -q '^hw.keyboard=' "$cfg" \
                && sed -i 's/^hw.keyboard=.*/hw.keyboard=yes/' "$cfg" \
                || echo 'hw.keyboard=yes' >> "$cfg"
        fi
    fi

    info "Setup complete."
    info "  AVD path:  $HOME/.android/avd/$AVD_NAME.avd"
    info "  AVD size:  $(du -sh "$HOME/.android/avd/$AVD_NAME.avd" 2>/dev/null | awk '{print $1}')"
}

cmd_boot() {
    require_sdk
    avd_exists || fail "AVD '$AVD_NAME' not found — run './tv-emulator.sh setup' first"

    if emu_booted; then
        info "Emulator already booted (serial: $("$ADB" devices | awk '/emulator/{print $1; exit}'))"
        return 0
    fi

    "$ADB" start-server >/dev/null 2>&1 || true

    info "Booting emulator '$AVD_NAME' (log: $EMU_LOG)..."
    # shellcheck disable=SC2086
    nohup "$EMULATOR" -avd "$AVD_NAME" \
        -no-snapshot-save -no-audio -no-boot-anim -gpu auto \
        ${EMU_FLAGS:-} \
        > "$EMU_LOG" 2>&1 &
    disown || true

    local t0 t1
    t0=$(date +%s)
    wait_for_boot
    t1=$(date +%s)
    info "Boot time: $((t1 - t0))s"

    info "Disabling animations..."
    "$ADB" shell settings put global window_animation_scale 0
    "$ADB" shell settings put global transition_animation_scale 0
    "$ADB" shell settings put global animator_duration_scale 0

    info "Devices:"
    "$ADB" devices | sed 's/^/    /'
}

cmd_install() {
    require_sdk
    emu_booted || fail "emulator not booted — run './tv-emulator.sh boot' first"
    [ -f "$APK_HOST" ]   || fail "cntv APK missing: $APK_HOST  (run ./build-cntv-release.sh x86_64)"
    [ -f "$APK_PLUGIN" ] || fail "v2ray plugin missing: $APK_PLUGIN  (run ./resign-v2ray-plugin.sh)"

    info "Installing host: $(basename "$APK_HOST")"
    "$ADB" install -r -g "$APK_HOST"
    info "Installing plugin: $(basename "$APK_PLUGIN")"
    "$ADB" install -r -g "$APK_PLUGIN"

    pkg_installed "$HOST_PKG"   || fail "$HOST_PKG not present after install"
    pkg_installed "$PLUGIN_PKG" || fail "$PLUGIN_PKG not present after install"

    info "Installed packages:"
    for p in "$HOST_PKG" "$PLUGIN_PKG"; do
        local ver
        ver=$("$ADB" shell dumpsys package "$p" 2>/dev/null | awk '/versionName=/ {print $1; exit}')
        printf "    %-45s %s\n" "$p" "${ver:-unknown}"
    done
}

cmd_launch() {
    require_sdk
    emu_booted || fail "emulator not booted"
    pkg_installed "$HOST_PKG" || fail "$HOST_PKG not installed — run install first"

    info "Starting $HOST_PKG/$HOST_ACTIVITY ..."
    "$ADB" logcat -c
    "$ADB" shell am start -W -n "$HOST_PKG/$HOST_ACTIVITY"

    info "Recent logcat (Shadowsocks/sslocal/v2ray/untrusted):"
    sleep 3
    "$ADB" logcat -d 2>/dev/null \
        | grep -iE "shadowsocks|sslocal|v2ray|untrusted" \
        | tail -20 \
        | sed 's/^/    /' \
        || info "    (no matching log lines yet — give the app a few seconds)"

    if "$ADB" logcat -d 2>/dev/null | grep -qi "untrusted"; then
        echo
        info "WARNING: 'untrusted' appeared in logcat — re-signing may not have matched. Inspect manually."
    else
        info "OK: no 'untrusted' marker in logcat (resigned plugin landed in trustedSignatures)."
    fi
}

cmd_up() {
    cmd_boot
    cmd_install
    cmd_launch
}

cmd_stop() {
    require_sdk
    if emu_booted || [ "$("$ADB" -e get-state 2>/dev/null || true)" = "device" ]; then
        info "Killing emulator..."
        "$ADB" emu kill 2>/dev/null || true
        sleep 2
        info "Stopped."
    else
        info "No running emulator."
    fi
}

cmd_status() {
    require_sdk
    if avd_exists; then
        echo "AVD:        present  ($HOME/.android/avd/$AVD_NAME.avd)"
    else
        echo "AVD:        MISSING  (run './tv-emulator.sh setup')"
    fi

    if emu_booted; then
        echo "Emulator:   booted   ($("$ADB" devices | awk '/emulator/{print $1; exit}'))"
    elif [ "$("$ADB" -e get-state 2>/dev/null || true)" = "device" ]; then
        echo "Emulator:   booting"
    else
        echo "Emulator:   stopped"
    fi

    if emu_booted; then
        local h=missing p=missing
        pkg_installed "$HOST_PKG"   && h=installed
        pkg_installed "$PLUGIN_PKG" && p=installed
        echo "Packages:   cntv=$h v2ray=$p"
    fi
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-}" in
    setup)   cmd_setup;;
    boot)    cmd_boot;;
    install) cmd_install;;
    launch)  cmd_launch;;
    up)      cmd_up;;
    stop)    cmd_stop;;
    status)  cmd_status;;
    "" | -h | --help | help)
        sed -n '2,18p' "$0" | sed 's/^# \?//'
        exit 0;;
    *)
        fail "unknown subcommand '$1'  (try: setup | boot | install | launch | up | stop | status)";;
esac
