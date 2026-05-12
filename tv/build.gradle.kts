plugins {
    id("com.android.application")
    id("com.google.android.gms.oss-licenses-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    kotlin("android")
}

setupApp()

// cntv must ship under its own signing identity (different cert fingerprint
// from freedom/google) so vendor blocklists can't cluster it back to the
// official Shadowsocks builds. Credentials come from gradle properties or env
// vars and stay outside the work tree; cntvDebug keeps the debug keystore.
val cntvKeystoreFile = file(
    (findProperty("CNTV_KEYSTORE_FILE") as String?)
        ?: System.getenv("CNTV_KEYSTORE_FILE")
        ?: "${System.getProperty("user.home")}/keystores/cntv-release.keystore"
)

android {
    namespace = "com.github.shadowsocks.tv"
    defaultConfig {
        applicationId = "com.github.shadowsocks.tv"
        buildConfigField("boolean", "FULLSCREEN", "false")
        buildConfigField("boolean", "ENABLE_FIREBASE", "true")
        // Optional: pre-populate the TV subscription URL on first launch.
        // Set DEFAULT_SUBSCRIPTION_URL in ~/.gradle/gradle.properties or pass -P at build time.
        // Empty by default. Note: value is interpolated raw — don't put `"` or `\` in the URL.
        buildConfigField(
            "String", "DEFAULT_SUBSCRIPTION_URL",
            "\"${findProperty("DEFAULT_SUBSCRIPTION_URL")?.toString().orEmpty()}\""
        )
    }
    signingConfigs {
        create("cntv") {
            if (cntvKeystoreFile.exists()) {
                storeFile = cntvKeystoreFile
                storeType = "PKCS12"
                storePassword = (findProperty("CNTV_KEYSTORE_PASSWORD") as String?)
                    ?: System.getenv("CNTV_KEYSTORE_PASSWORD") ?: ""
                keyAlias = (findProperty("CNTV_KEY_ALIAS") as String?)
                    ?: System.getenv("CNTV_KEY_ALIAS") ?: "cntv"
                keyPassword = (findProperty("CNTV_KEY_PASSWORD") as String?)
                    ?: System.getenv("CNTV_KEY_PASSWORD") ?: storePassword
            }
        }
    }
    flavorDimensions.add("market")
    productFlavors {
        create("freedom") {
            dimension = "market"
        }
        create("google") {
            dimension = "market"
            buildConfigField("boolean", "FULLSCREEN", "true")
        }
        create("cntv") {
            dimension = "market"
            // Default disguise package; override per build via -PCNTV_APPLICATION_ID=...
            // or env CNTV_APPLICATION_ID when a vendor blocklists the default.
            applicationId = (findProperty("CNTV_APPLICATION_ID") as String?)
                ?: System.getenv("CNTV_APPLICATION_ID")
                ?: "com.github.skcoswodahs.tv"
            buildConfigField("boolean", "ENABLE_FIREBASE", "false")
            // Only attach the cntv signingConfig when the keystore is present,
            // so debug builds and CI without credentials still complete.
            // buildTypes.debug.signingConfig (= debug) overrides this for cntvDebug;
            // buildTypes.release.signingConfig is unset module-wide so cntvRelease
            // falls back to this flavor signingConfig.
            if (cntvKeystoreFile.exists()) {
                signingConfig = signingConfigs.getByName("cntv")
            }
        }
    }
}

// cntv ships in environments where Firebase is unreachable; skip the build-time
// google-services / Crashlytics tasks so missing client entries don't fail the build.
tasks.whenTaskAdded {
    if (name.contains("Cntv") &&
        (name.contains("GoogleServices", ignoreCase = true) ||
         name.contains("Crashlytics", ignoreCase = true) ||
         name.contains("FirebaseInstallations", ignoreCase = true))) {
        enabled = false
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar)
    implementation(libs.androidx.leanback.preference)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.test.runner)
}
