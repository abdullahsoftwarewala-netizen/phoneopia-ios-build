import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing — credentials from env vars (CI) or gitignored key.properties (local only)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun signingValue(propKey: String, envKey: String): String? {
    val fromEnv = System.getenv(envKey)?.trim()
    if (!fromEnv.isNullOrEmpty()) return fromEnv
    return keystoreProperties.getProperty(propKey)?.trim()?.takeIf { it.isNotEmpty() }
}

fun resolveStoreFile(): java.io.File? {
    val path = signingValue("storeFile", "PHONEOPIA_STORE_FILE") ?: return null
    val f = file(path)
    return if (f.exists()) f else file("${rootProject.projectDir}/$path").takeIf { it.exists() }
}

val hasReleaseSigning = resolveStoreFile() != null
    && signingValue("storePassword", "PHONEOPIA_STORE_PASSWORD") != null
    && signingValue("keyPassword", "PHONEOPIA_KEY_PASSWORD") != null
    && signingValue("keyAlias", "PHONEOPIA_KEY_ALIAS") != null

android {
    namespace = "com.phoneopia.phoneopia_mobile"
    compileSdk = flutter.compileSdkVersion
    // Pinned explicitly (not flutter.ndkVersion) — Play Console rejected the
    // upload for missing 16 KB memory page size support; r28+ is required
    // for that, and Flutter's own default NDK pin can lag behind it.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.phoneopia.phoneopia_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Phoneopia distribution target is arm64; limiting native
            // libraries keeps the Play Store bundle and release packaging
            // within this machine's memory budget.
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                keyAlias = signingValue("keyAlias", "PHONEOPIA_KEY_ALIAS")!!
                keyPassword = signingValue("keyPassword", "PHONEOPIA_KEY_PASSWORD")!!
                storeFile = resolveStoreFile()!!
                storePassword = signingValue("storePassword", "PHONEOPIA_STORE_PASSWORD")!!
            }
        }
    }

    buildTypes {
        release {
            // Fixed key so Play Store updates keep same signature. Debug fallback for local dev.
            signingConfig = if (hasReleaseSigning)
                signingConfigs.getByName("release")
            else signingConfigs.getByName("debug")
            // R8 OOMs on this low-memory build machine; not needed for direct OTA distribution.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // Keep the release bundle lean. Native debug symbols are not needed inside
    // the Play upload; keeping them here was a major contributor to the large
    // AAB and made packageRelease run out of disk on this machine.
    packaging {
        jniLibs {
            // Vulkan validation layers are debug tooling, not required by the
            // Phoneopia app, and make low-disk debug builds unnecessarily huge.
            excludes += "**/libVkLayer_khronos_validation.so"
        }
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
