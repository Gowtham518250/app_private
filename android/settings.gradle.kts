import org.gradle.api.tasks.Exec

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// Make the APK build deterministic: apply the verified production bug fixes
// immediately before Android's preBuild task, so the compiled Flutter sources
// are the fixed sources even when the checkout still contains old Dart files.
gradle.projectsEvaluated {
    val appProject = gradle.rootProject.findProject(":app") ?: return@projectsEvaluated
    val repoRoot = gradle.rootProject.projectDir.parentFile
    val pythonExecutable = if (System.getProperty("os.name").lowercase().contains("windows")) {
        "python"
    } else {
        "python3"
    }

    val patchTask = appProject.tasks.register<Exec>("applyRetailMindProductionFixes") {
        workingDir(repoRoot)
        commandLine(pythonExecutable, "tools/apply_production_bug_fixes.py")
    }

    appProject.tasks.matching { it.name == "preBuild" }.configureEach {
        dependsOn(patchTask)
    }
}
