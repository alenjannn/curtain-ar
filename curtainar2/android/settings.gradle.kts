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
    // Must stay on Gradle/AGP 8.x: ar_flutter_plugin_updated 0.0.1 uses
    // `configurations.all` as a property, which Gradle 9 removed. These are Flutter's
    // minimum supported 8.x versions. Do not bump to 9.x without first confirming the
    // AR plugin's build.gradle has been modernised.
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// `:unityLibrary` is NOT optional. flutter_unity_widget's own build.gradle does
// `implementation project(':unityLibrary')` with no guard, and it lives in the pub cache where we
// cannot patch it — so if this project is missing, evaluating :flutter_unity_widget fails and
// NOTHING builds, including the ARCore screen that never touches Unity.
//
// It is also routinely absent. Unity's exporter opens with
// `Directory.Delete(AndroidExportPath, true)` (FlutterUnityIntegration/Editor/Build.cs), so a
// Unity build that fails for any reason — a bad graphics API, a compile error, a cancelled
// build — leaves android/unityLibrary deleted and the Flutter app unbuildable until it is
// restored by hand.
//
// So resolve to whichever exists. The real export wins when present; otherwise a committed
// placeholder module keeps the build green, and the app says on screen that Unity is missing.
// unityLibraryPlaceholder/ sits outside the export path, so Unity can never delete it.
val unityExport = file("./unityLibrary")
val unityPlaceholder = file("./unityLibraryPlaceholder")

fun isGradleModule(dir: File) =
    dir.resolve("build.gradle").exists() || dir.resolve("build.gradle.kts").exists()

val unityLibraryDir = when {
    isGradleModule(unityExport) -> unityExport
    isGradleModule(unityPlaceholder) -> unityPlaceholder
    else -> throw GradleException(
        """
        Neither android/unityLibrary nor android/unityLibraryPlaceholder is a Gradle module, and
        flutter_unity_widget requires :unityLibrary to build at all.

        Restore the placeholder:  git checkout -- android/unityLibraryPlaceholder
        Or export the real thing: open unity/CurtainAR in the Unity Editor and run
                                  Flutter > Export Android (Debug).
        """.trimIndent()
    )
}

if (unityLibraryDir == unityPlaceholder) {
    logger.lifecycle(
        "WARNING: android/unityLibrary not found - building against the placeholder. " +
            "The Unity AR screen will not work. Run Flutter > Export Android (Debug) in the " +
            "Unity Editor. See android/unityLibraryPlaceholder/README.md."
    )
}

include(":unityLibrary")
project(":unityLibrary").projectDir = unityLibraryDir

// Unity 6 splits the XR/ARCore manifest into a nested `xrmanifest.androidlib` module, and the
// generated unityLibrary/build.gradle depends on it as `project(':unityLibrary:xrmanifest.androidlib')`.
// Unity's own settings.gradle includes it; ours has to as well or :unityLibrary fails to resolve.
// The placeholder has no such module, hence the existence check.
val xrManifestDir = File(unityLibraryDir, "xrmanifest.androidlib")
if (isGradleModule(xrManifestDir)) {
    include(":unityLibrary:xrmanifest.androidlib")
    project(":unityLibrary:xrmanifest.androidlib").projectDir = xrManifestDir
}
