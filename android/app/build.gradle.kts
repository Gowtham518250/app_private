import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")  // Google Services plugin for Firebase
}

// Release credentials must come from android/key.properties (gitignored) or
// environment variables. Never store passwords or a developer-specific keystore
// path in the repository.
val releaseKeyPropertiesFile = rootProject.file("key.properties")
val releaseKeyProperties = Properties().apply {
    if (releaseKeyPropertiesFile.exists()) {
        releaseKeyPropertiesFile.inputStream().use { load(it) }
    }
}

fun releaseSetting(environmentName: String, propertyName: String): String? =
    System.getenv(environmentName)?.takeIf { it.isNotBlank() }
        ?: releaseKeyProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val releaseStoreFilePath = releaseSetting("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = releaseSetting("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = releaseSetting("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = releaseSetting("ANDROID_KEY_PASSWORD", "keyPassword")

android {
    namespace = "com.retailmind.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.retailmind.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Missing secrets deliberately leave the release build unconfigured;
            // provide them locally via android/key.properties or in CI secrets.
            if (!releaseStoreFilePath.isNullOrBlank()) {
                storeFile = file(releaseStoreFilePath)
            }
            storePassword = releaseStorePassword ?: ""
            keyAlias = releaseKeyAlias ?: ""
            keyPassword = releaseKeyPassword ?: ""
        }
    }

    buildTypes {
        release {
            // 🔧 CRITICAL: Set your own signing config before publishing to Play Store.
            signingConfig = signingConfigs.getByName("release")
            // 🔧 FIX: this was missing entirely — the release build runs R8
            // minification (Flutter's default) with zero app-level keep
            // rules, which is what caused the WorkDatabase crash. See
            // proguard-rules.pro for the full explanation.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.sqlite:sqlite-framework:2.4.0")
    implementation("androidx.sqlite:sqlite:2.4.0")
}