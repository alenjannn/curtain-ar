package com.unity3d.player;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.util.Log;
import android.view.Gravity;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * PLACEHOLDER — this is not Unity.
 *
 * <p>The real class ships inside {@code libs/unity-classes.jar} of a Unity Android export. This
 * stand-in exists only so {@code :flutter_unity_widget} can compile: that module declares
 * {@code implementation project(':unityLibrary')} unconditionally, so without something at that
 * coordinate the whole Gradle build fails to configure.
 *
 * <p>Everything here is inert. There is no AR session, no camera feed, and
 * {@link #UnitySendMessage} discards every message Flutter posts. The view therefore renders an
 * explicit on-screen notice rather than a plausible-looking black rectangle — a silent placeholder
 * is indistinguishable from a Unity scene that failed to start, and that ambiguity costs hours.
 *
 * <p>Only the surface {@code flutter_unity_widget} actually calls is declared: the two
 * constructors, the static {@link #UnitySendMessage}, and the lifecycle methods. Everything else
 * it uses ({@code parent}, {@code z}, {@code requestLayout()}, {@code invalidate()},
 * {@code requestFocus()}) is inherited from {@link FrameLayout} and must NOT be overridden here —
 * stubbing those out stops the view laying out or drawing its children.
 *
 * <p>See {@code android/unityLibraryPlaceholder/README.md}.
 */
public class UnityPlayer extends FrameLayout {
    private static final String TAG = "UnityPlaceholder";

    private static final String NOTICE =
            "Unity runtime not bundled\n\n"
                    + "Gradle fell back to unityLibraryPlaceholder because\n"
                    + "android/unityLibrary does not exist.\n\n"
                    + "In the Unity Editor, open unity/CurtainAR and run\n"
                    + "Flutter → Export Android (Debug), then rebuild.";

    /** Real Unity sets this to the hosting activity. Nothing in the plugin reads it. */
    public static Activity currentActivity;

    public UnityPlayer(Context context) {
        super(context);
        showNotice(context);
    }

    public UnityPlayer(Context context, IUnityPlayerLifecycleEvents events) {
        super(context);
        showNotice(context);
    }

    private void showNotice(Context context) {
        Log.e(TAG, "Unity runtime not bundled - built against unityLibraryPlaceholder. "
                + "Run Flutter > Export Android (Debug) from the Unity Editor.");

        setBackgroundColor(Color.parseColor("#0A1A33"));

        TextView notice = new TextView(context);
        notice.setText(NOTICE);
        notice.setTextColor(Color.WHITE);
        notice.setTextSize(15f);
        notice.setGravity(Gravity.CENTER);
        notice.setPadding(48, 48, 48, 48);

        addView(notice, new LayoutParams(
                LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER));
    }

    /**
     * Real Unity routes this into the scripting runtime. Here it is a dead end, so every call is
     * logged — this is the most useful line in logcat when the bridge appears to do nothing.
     */
    public static void UnitySendMessage(String gameObject, String methodName, String message) {
        Log.w(TAG, "Dropped message to " + gameObject + "." + methodName + "(" + message + ") "
                + "- no Unity runtime is bundled.");
    }

    public void windowFocusChanged(boolean hasFocus) {}

    public void resume() {}

    public void pause() {}

    public void unload() {}

    public void quit() {}

    public void destroy() {}

    public void lowMemory() {}

    public void bringToFront() {}
}
