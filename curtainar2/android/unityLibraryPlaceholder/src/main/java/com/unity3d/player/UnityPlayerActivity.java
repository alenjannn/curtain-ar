package com.unity3d.player;

import android.app.Activity;

/**
 * PLACEHOLDER — see {@link UnityPlayer} and this directory's README.md.
 *
 * <p>flutter_unity_widget's {@code OverrideUnityActivity} extends this, reads {@link #mUnityPlayer}
 * and overrides {@link #onUnityPlayerUnloaded()}, so both must exist and stay non-final. The
 * activity is only reached in the plugin's fullscreen/native flow, which this app does not use —
 * the embedded {@code UnityWidget} path never instantiates it.
 */
public class UnityPlayerActivity extends Activity implements IUnityPlayerLifecycleEvents {
    /** Null here for the same reason everything else is inert: there is no player to hold. */
    protected UnityPlayer mUnityPlayer;

    @Override
    public void onUnityPlayerUnloaded() {}

    @Override
    public void onUnityPlayerQuitted() {}
}
