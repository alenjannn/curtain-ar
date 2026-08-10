# `unityLibraryPlaceholder` — the fallback for `:unityLibrary`

**Do not delete this directory, and do commit it.** It is what keeps the app buildable when
`android/unityLibrary` is missing.

## Why it exists

`flutter_unity_widget`'s Android module declares, in its own `build.gradle` (line 58):

```groovy
implementation project(':unityLibrary')
implementation(name: 'unity-classes', ext: 'jar')
```

That is unconditional and lives in the pub cache, so it cannot be guarded from this repo. With no
`:unityLibrary` project, Gradle fails while evaluating `:flutter_unity_widget` and **nothing**
builds — including the ARCore screen, which has no connection to Unity at all.

And `android/unityLibrary` disappears easily. Unity's exporter opens with:

```csharp
if (Directory.Exists(AndroidExportPath))
    Directory.Delete(AndroidExportPath, true);   // FlutterUnityIntegration/Editor/Build.cs
```

It deletes *first*, builds *second*. So any Unity build failure — a bad graphics API, a compile
error, a cancelled build — leaves the directory gone and the Flutter app unbuildable.

`android/settings.gradle.kts` therefore points `:unityLibrary` at whichever of these exists:

| Present | `:unityLibrary` resolves to | Unity AR screen |
|---|---|---|
| `android/unityLibrary` | the real export | works |
| neither | this placeholder | shows "Unity runtime not bundled" |

This directory sits outside Unity's export path, so Unity can never delete it.

## What being on the placeholder means

The app compiles, installs and runs, but the Unity AR screen cannot work:

| | Real export | This placeholder |
|---|---|---|
| `libs/unity-classes.jar` | Unity's compiled runtime | manifest-only stub |
| `src/main/jniLibs/**/libunity.so` | native player | absent |
| `src/main/assets/bin/Data/**` | the built scene | absent |
| `UnitySendMessage` | routes into C# | logs and discards |
| On screen | camera feed + panel | a "runtime not bundled" notice |

A placement tap, a swatch tap and a resize gesture all leave Flutter, reach
`UnityPlayer.UnitySendMessage`, and stop there. Nothing comes back, which is why the Flutter screen
raises its own "Unity runtime not bundled" card after ~30 seconds rather than waiting forever on a
scene that will never load.

Gradle also prints a `WARNING: android/unityLibrary not found` line on every build that falls back
here.

## Getting the real export

1. Open `unity/CurtainAR` in Unity.
2. If the scene needs regenerating: **Curtain AR → Build AR Scene**.
3. **Flutter → Export Android (Debug)**.
4. Rebuild: `flutter run`.

Nothing needs deleting first — `settings.gradle.kts` switches to the export automatically the
moment it appears.

### Settings that must hold, or the export fails

Both were wrong once and cost a full debugging cycle:

- **Graphics APIs must not include Vulkan** (Player Settings → Android → Graphics APIs).
  ARCore + Vulkan forces `minSdk >= 29`; with OpenGLES3 alone, 26 is fine. Getting this wrong
  produces `BuildFailedException: ARCore Required apps using Vulkan require a minimum SDK version
  of AndroidApiLevel29`.
- **Unity's `AndroidMinSdkVersion` must match `android/app/build.gradle.kts`'s `minSdk`** (both 26).
  A library minSdk above the app's fails the manifest merger.

### Verifying which one you have

```sh
ls android/unityLibrary/src/main/jniLibs/arm64-v8a/libunity.so   # must exist
```

If it is missing, you are still on the placeholder.
