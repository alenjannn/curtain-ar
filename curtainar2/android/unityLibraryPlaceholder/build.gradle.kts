// Stand-in for :unityLibrary, used only while android/unityLibrary is absent.
// See README.md in this directory. Nothing here is Unity.

plugins {
    id("com.android.library")
}

android {
    namespace = "com.unity3d.player"
    compileSdk = 36

    defaultConfig {
        // Matches Unity's AndroidMinSdkVersion so swapping to a real export changes nothing
        // about how the app module's manifest merges.
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
