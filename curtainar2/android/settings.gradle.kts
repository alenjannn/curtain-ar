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
    // AR plugin's bud.gradle has been modernised.
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

// A Flutter rebuild does not re-export Unity. Refuse to silently package an older Unity player
// when a scene, model, prefab, material, script, package, or build-relevant setting changed after
// android/unityLibrary was generated. This is the exact failure mode that made the Editor show the
// corrected curtain while the phone kept running the old spiked _Curtain_Curtain prefab and old
// fixed-2-cm resize code.
if (unityLibraryDir == unityExport) {
    val unityProjectDir = file("../unity/CurtainAR")
    val exportMarker = unityExport.resolve("src/main/assets/bin/Data/globalgamemanagers")
    val watchedUnityPaths =
        listOf(
            unityProjectDir.resolve("Assets"),
            unityProjectDir.resolve("Packages/manifest.json"),
            unityProjectDir.resolve("Packages/packages-lock.json"),
            unityProjectDir.resolve("ProjectSettings/EditorBuildSettings.asset"),
            unityProjectDir.resolve("ProjectSettings/GraphicsSettings.asset"),
            unityProjectDir.resolve("ProjectSettings/ProjectSettings.asset"),
            unityProjectDir.resolve("ProjectSettings/QualitySettings.asset"),
            unityProjectDir.resolve("ProjectSettings/URPProjectSettings.asset"),
        )

    val newestUnitySource =
        watchedUnityPaths
            .asSequence()
            .filter { it.exists() }
            .flatMap { path -> if (path.isDirectory) path.walkTopDown().asSequence() else sequenceOf(path) }
            .filter { it.isFile }
            .maxByOrNull { it.lastModified() }

    if (!exportMarker.isFile) {
        throw GradleException(
            "android/unityLibrary is incomplete: ${exportMarker.relativeTo(rootDir)} is missing. " +
                "In Unity, run Flutter > Export Android (Debug) and wait for SUCCESSFUL."
        )
    }

    // FAT/ZIP timestamp precision can be two seconds; allow that much clock granularity.
    if (newestUnitySource != null && newestUnitySource.lastModified() > exportMarker.lastModified() + 2_000L) {
        val sourceTime = java.time.Instant.ofEpochMilli(newestUnitySource.lastModified())
        val exportTime = java.time.Instant.ofEpochMilli(exportMarker.lastModified())
        throw GradleException(
            """
            The Unity Android export is stale, so Flutter would install an older curtain than the one in the Unity Editor.

            Newest Unity source: ${newestUnitySource.relativeTo(unityProjectDir)} ($sourceTime)
            Android Unity export: ${exportMarker.relativeTo(rootDir)} ($exportTime)

            Open unity/CurtainAR in Unity and run Flutter > Export Android (Debug). Wait for the
            successful export, then run flutter clean and flutter run again.
            """.trimIndent()
        )
    }
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
