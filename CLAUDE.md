# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Prerequisites

- JDK 11+ (CI uses JetBrains JDK 21)
- Android SDK + NDK
- Rust with Android targets: `rustup target add armv7-linux-androideabi aarch64-linux-android i686-linux-android x86_64-linux-android`
- Python 3 (required by the rust-android-gradle plugin's linker wrapper)
- Submodules must be checked out: `git submodule update --init --recursive` (the JNI C deps under `core/src/main/jni/` and `shadowsocks-rust` under `core/src/main/rust/` are git submodules — without them, the build will fail in non-obvious ways)

## Build commands

The project uses Gradle (Kotlin DSL) with four modules: `:core`, `:plugin`, `:mobile`, `:tv`.

```bash
# Full debug build of phone app (all ABIs — slow because cargo + ndk-build run per ABI)
./gradlew :mobile:assembleDebug

# Single-ABI debug build (much faster; what CI uses for E2E)
./gradlew :mobile:assembleDebug -PCARGO_PROFILE=debug -PTARGET_ABI=x86_64
# TARGET_ABI accepts: arm | arm64 | x86 | x86_64

# TV build
./gradlew :tv:assembleDebug

# Release build (R8 + resource shrinking enabled, splits per ABI + universal APK)
./gradlew :mobile:assembleRelease

# Lint / static analysis
./gradlew lint
./gradlew detekt   # config in detekt.yml

# Cargo clean is wired into gradle clean
./gradlew clean
```

`-PCARGO_PROFILE` and `-PTARGET_ABI` are read in `core/build.gradle.kts`; without `CARGO_PROFILE` the cargo profile is inferred from the gradle task name (`Release` → release, otherwise debug). When iterating, always pass `-PTARGET_ABI` — a full build compiles `shadowsocks-rust` four times and the C JNI for four ABIs.

Common-config DSL lives in `buildSrc/src/main/kotlin/Helpers.kt` (`setupCommon` / `setupCore` / `setupApp`). Versions (`versionCode`, `versionName`) are set there, not in module `build.gradle.kts` files.

## Tests

```bash
# Unit tests
./gradlew :core:testDebugUnitTest

# Instrumented tests (require a connected device/emulator)
./gradlew :core:connectedDebugAndroidTest

# Single test class
./gradlew :core:testDebugUnitTest --tests "com.github.shadowsocks.SomeTest"
```

End-to-end test (`test-e2e.sh`) boots an emulator, runs `ssserver` on the host, installs the debug APK, rewrites the default `Profile` row in `profile.db` via `run-as` + `sqlite3`, taps the FAB to start the VPN, and verifies tun0 + connectivity. Honors `EMULATOR`, `ADB`, `AVD`, `APK`, `SSSERVER`, `SKIP_EMULATOR_BOOT` env vars. CI runs this via `.github/workflows/e2e-test.yml` against API 34 x86_64.

## Architecture

### Module layout

- **`:plugin`** — public SDK published to Maven (`com.github.shadowsocks:plugin`) for third-party plugin authors (v2ray, kcptun, simple-obfs). Defines `NativePluginProvider`, `ConfigurationActivity`, `HelpActivity`, plugin intents/authorities. See `plugin/README.md` and `plugin/doc.md`. Changes here are part of a public ABI — be careful.
- **`:core`** — the engine. Native code (C via ndk-build, Rust via cargo), Room databases, AIDL service interface, VPN/proxy/transproxy services, ACL, subscription management, DNS, networking utilities. Both apps depend on this. `:core` depends on `:plugin`.
- **`:mobile`** — the phone/tablet app (`com.github.shadowsocks`). Material UI, profile editing, QR scanning, Tasker integration.
- **`:tv`** — the Android TV app. Leanback UI on top of the same `:core`. Three product flavors on the `market` dimension:
  - `freedom` — FOSS / F-Droid build, `applicationId = com.github.shadowsocks.tv`, Firebase enabled.
  - `google` — Play Store build, same `applicationId`, Firebase enabled, `BuildConfig.FULLSCREEN = true` (settings panel uses `MATCH_PARENT` width — see `tv/src/main/java/com/github/shadowsocks/tv/MainFragment.kt`).
  - `cntv` — disguise build for Chinese TVs that blocklist `com.github.shadowsocks.tv`. `applicationId = com.github.skcoswodahs.tv`, `app_name` overridden to "网络工具箱" (with zh-rTW + fa locale overrides), Firebase **disabled at both build and runtime** (see "cntv flavor" section below). Signed with a dedicated keystore, not the official one.

`:mobile` and `:tv` are deliberately separate apps, not flavors — keep platform-specific UI out of `:core`.

### Native binary stack

The VPN data path runs as native binaries spawned by Kotlin (`bg/GuardedProcessPool.kt`, `bg/Executable.kt`):

- **`shadowsocks-rust`** (`core/src/main/rust/shadowsocks-rust/`, submodule) → `libsslocal.so`. Built by the `cargo` block in `core/build.gradle.kts` with a curated feature set (`stream-cipher`, `aead-cipher-extra`, `local-flow-stat`, `local-dns`, `aead-cipher-2022`). Packaged as a JNI lib but invoked as an executable.
- **`badvpn` / `tun2socks`**, **`redsocks`**, **`libevent`**, **`libancillary`** (all submodules under `core/src/main/jni/`) → built by `ndkBuild` via `core/src/main/jni/Android.mk`.
- The 16KB-page-size requirement is honored via a custom linker arg in the `cargo { exec = ... }` block — preserve it when touching the rust build config.

### Service architecture

`bg/BaseService.kt` defines the shared lifecycle (`Interface`/`Data`/`Binder`) used by three concrete `Service`s:

- `bg/VpnService.kt` — `VpnService` mode (default; uses `tun0` + `tun2socks`)
- `bg/ProxyService.kt` — local SOCKS proxy mode (no VPN permission)
- `bg/TransproxyService.kt` — transparent proxy mode (root)

The active mode is chosen by `DataStore.serviceMode` (`Key.modeVpn` / `modeProxy` / `modeTransproxy`). UI never imports a concrete service — it talks to whichever is bound through the **AIDL** interface in `core/src/main/aidl/com/github/shadowsocks/aidl/` (`IShadowsocksService`, `IShadowsocksServiceCallback`, `TrafficStats`). The `ShadowsocksConnection` helper is the standard binding point from activities/fragments.

`Core` (singleton `object` in `core/src/main/java/com/github/shadowsocks/Core.kt`) is initialized from each app's `Application.onCreate` and exposes app-wide singletons (Firebase, DataStore, Profile DB, system services, direct-boot context). Treat it as the entry point for cross-cutting concerns.

### Persistence

Two Room databases (`database/PrivateDatabase.kt`, `database/PublicDatabase.kt`) — keep migrations in `database/migration/`, and exported schemas in `core/schemas/` (Room is configured to write them there via the KSP arg). Settings are stored as `KeyValuePair` rows accessed through `preference/DataStore.kt`, not Android `SharedPreferences` — use `DataStore` + `Key.*` constants for all settings reads/writes.

### Plugin system

Plugins are independent APKs that expose a `ContentProvider` with action `com.github.shadowsocks.plugin.ACTION_NATIVE_PLUGIN`. They ship a native binary (or path to one), and optionally a `ConfigurationActivity` and `HelpActivity`. The host app discovers them through PackageManager queries, copies their binary into the app's data dir if needed, and execs it alongside `sslocal`. Anything in `:plugin` is API the outside world consumes — breaking changes need a bump and a `plugin/CHANGES.md` entry.

### `cntv` flavor (Chinese-TV disguise build)

Some Chinese smart-TV vendors blocklist `com.github.shadowsocks.tv` by package name. The `cntv` flavor in `tv/build.gradle.kts` exists to evade this and has several non-obvious mechanisms:

- **`applicationId`** is `com.github.skcoswodahs.tv` (`shadowsocks` reversed). The `namespace` (R-class package) stays `com.github.shadowsocks.tv` — AGP allows the two to differ, so all Kotlin source under `com.github.shadowsocks.tv.*` is unchanged.
- **Display name** is overridden via `tv/src/cntv/res/values{,-zh-rTW,-fa}/strings.xml` because `:core` ships translated `app_name` strings in those locales that would otherwise leak the original brand.
- **Firebase is disabled at build time** by `tv/build.gradle.kts`'s `tasks.whenTaskAdded { if (name.contains("Cntv") && ...) enabled = false }` block — `tv/google-services.json` does not list the disguise package, so the `google-services` plugin would otherwise fail. **And at runtime** by `BuildConfig.ENABLE_FIREBASE = false` (set per flavor), which `tv/src/main/.../App.kt` passes to `Core.init(..., enableFirebase = ...)`. The third `Core.init` parameter gates `FirebaseApp.initializeApp`, `FirebaseCrashlytics.*`, and `FirebaseAnalytics.*` everywhere they're called (`Core.kt`, `bg/BaseService.kt`, `mobile/.../MainActivity.kt`). When adding a new Firebase call site, **always wrap it in `if (Core.enableFirebase)`** or it will NPE on cntv.
- **Signing is per-flavor**: cntv must NOT share a signing cert with `freedom`/`google` or vendors can fingerprint it back. `tv/build.gradle.kts` defines `signingConfigs.cntv` keyed off `CNTV_KEYSTORE_FILE` / `CNTV_KEYSTORE_PASSWORD` / `CNTV_KEY_ALIAS` / `CNTV_KEY_PASSWORD` (Gradle properties or env vars). The signingConfig is **conditionally** attached to the `cntv` flavor only when the keystore file exists, so debug builds and CI without credentials still complete (cntvDebug uses the standard Android debug keystore via `buildTypes.debug.signingConfig`; cntvRelease falls back to the flavor signingConfig). The default keystore path is `~/keystores/cntv-release.keystore` (PKCS12). Credentials live in `~/.gradle/gradle.properties`, never the repo.
- **Known leakage**: the launchable activity class name is still `com.github.shadowsocks.tv.MainActivity` (visible to `pm dump` / `aapt dump badging`). Sufficient if vendors only check `applicationId` (most do); if a future blocklist inspects activity class names, the package would need to be relocated — large change, deferred.

When adding flavor-specific assets / strings / themes for cntv, mirror the `tv/src/freedom/` source-set layout, not `tv/src/main/`.

## Conventions worth knowing

- Kotlin only for new code; Java interop is preserved in `:plugin` for third-party plugin authors.
- `kotlin-parcelize` is used throughout — prefer `@Parcelize` over manual `Parcelable`.
- Direct boot: `Core.deviceStorage` returns a device-protected-storage `Context` on API 24+; some preferences and the boot receiver run before user unlock. Don't assume credential-protected storage is available at app start.
- Coroutines for everything async; `GlobalScope` is used in `BaseService` deliberately to outlive the binder lifecycle — don't "fix" it without understanding the service teardown sequence.
- Translations go through POEditor (see README link); don't hand-edit non-`values/` string resources.
- `release.sh` produces signed builds — release engineering only.
