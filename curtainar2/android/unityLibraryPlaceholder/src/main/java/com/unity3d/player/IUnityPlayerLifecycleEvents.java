package com.unity3d.player;

/**
 * PLACEHOLDER — see {@link UnityPlayer} and this directory's README.md.
 *
 * <p>Mirrors the real interface's shape so {@code CustomUnityPlayer} and
 * {@code OverrideUnityActivity} in flutter_unity_widget compile against it.
 */
public interface IUnityPlayerLifecycleEvents {
    void onUnityPlayerUnloaded();

    void onUnityPlayerQuitted();
}
