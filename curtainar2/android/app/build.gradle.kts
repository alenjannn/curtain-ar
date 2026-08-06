plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.curtainar2"
    // geolocator_android (transitive via ar_flutter_plugin_updated) must be compiled
    // against SDK 36. compileSdk is backward compatible and does not change runtime
    // behaviour — targetSdk stays at 34.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.curtainar2"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ARCore requires API 24+, but this must be >= Unity's AndroidMinSdkVersion (26, in
        // unity/CurtainAR/ProjectSettings/ProjectSettings.asset) or the manifest merger rejects
        // the exported :unityLibrary with "uses-sdk:minSdkVersion 24 cannot be smaller than
        // version 26 declared in library". Keep the two in step.
        minSdk = 26
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// Two copies of the ARCore client SDK land on the runtime classpath and D8 refuses to merge
// them: ar_flutter_plugin_updated depends on com.google.ar:core:1.33.0, while Unity's
// :unityLibrary bundles arcore_client.aar (SDK 1.45). They share the whole
// com.google.ar.core.* and com.google.vr.dynamite.client.* class space, so it fails with
// "Duplicate class com.google.vr.dynamite.client.d found in modules ...".
//
// Drop the Maven one and let everything bind against Unity's bundled AAR. That direction is
// forced: Unity's native runtime is built against exactly its own arcore_client, whereas
// ar_flutter_plugin_updated only calls long-stable ARCore APIs that 1.45 still provides.
// This affects :app's own configurations only — ar_flutter_plugin_updated still compiles
// against 1.33 inside its own module.
configurations.all {
    exclude(group = "com.google.ar", module = "core")
}

dependencies {
    // Unconditional: settings.gradle.kts always includes :unityLibrary and fails with an
    // actionable message if the directory is gone, so there is no "absent" case left to guard.
    implementation(project(":unityLibrary"))
}
