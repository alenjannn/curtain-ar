# Simply Curtains AR

## Run on an Android phone

Prerequisites:

- Flutter SDK installed and available on `PATH`
- Android Studio with the Android SDK installed
- JDK 17 (the Android project is configured for Java 17)
- An ARCore-compatible Android phone running Android 8.0/API 26 or later
- Developer options and USB debugging enabled on the phone

From a fresh clone:

```sh
flutter doctor
flutter pub get
flutter devices
flutter run
```

Accept any Android SDK licences requested by `flutter doctor`. The first run
downloads the Flutter/Dart and Gradle dependencies, so it needs internet access.

The repository intentionally includes a tiny `android/unityLibraryPlaceholder`
module. This is required because the Unity Flutter plugin expects a Unity module
at Android build time. It means a collaborator can build and run the normal
Flutter app without installing Unity or downloading a multi-gigabyte Unity
export.

The dedicated Unity AR experience is not included in that fallback. It displays
an in-app notice until a Unity developer exports the runtime locally. To enable
it, install the project's Unity version, open `unity/CurtainAR`, then use
`Flutter > Export Android (Debug)`. This creates the ignored
`android/unityLibrary` directory, which automatically takes precedence over the
fallback on the next `flutter run`.

Whenever a Unity scene, model, prefab, material, script, package, or relevant
project setting changes, export Android again before running Flutter. The
Android build checks this automatically and stops with a clear “Unity Android
export is stale” message instead of silently packaging an older scene.

## iPhone

Running on iPhone requires macOS, Xcode, an Apple signing team, and an
ARKit-capable device. Connect the device and use the same `flutter pub get` and
`flutter run` commands from a Mac.
