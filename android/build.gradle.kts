plugins {
    id("com.google.gms.google-services") version "4.4.0" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// The published blue_thermal_printer 1.2.3 plugin declares its Android package
// in AndroidManifest.xml but doesn't set the namespace required by AGP 8+.
// Configure it as soon as the library plugin is applied (before variant creation).
subprojects {
    plugins.withId("com.android.library") {
        if (name == "blue_thermal_printer") {
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                if (namespace.isNullOrBlank()) {
                    namespace = "id.kakzaki.blue_thermal_printer"
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
