package org.photowagon.mobile;

import android.app.Notification;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.util.Log;
import java.io.File;
import org.json.JSONObject;
import org.qtproject.qt.android.bindings.QtService;

/**
 * The phone's core — indexer, faces, sync, p2p — in its own process (":core", see the
 * manifest), apart from the activity's UI.
 *
 * Everything used to run in the activity process, on the UI's Qt thread: heavy work froze
 * the UI, backgrounding or roaming took the whole app down, and a crash in the p2p stack
 * killed the screen with it. A QtService in a separate process loads the SAME .so and calls
 * its main() again with "-service" (android.app.arguments), which the D side dispatches to
 * the core's own entry (coremain.d) — no QML, no window.
 *
 * Foreground only while there is background work to keep going — auto-sync on, the same
 * settings/autosync flag MainActivity uses for SyncService. A foreground service keeps the
 * process out of Android's cached-app freezer (it does NOT exempt it from Doze's network
 * restrictions: after an idle period the core must reconnect, which netWatch does on
 * resume). It is also budgeted: Android 15+ gives dataSync services six hours per 24 h,
 * shared by the app, and ends an exhausted one through onTimeout() — so the core does not
 * sit in the foreground just to exist. With auto-sync off it is an ordinary started service,
 * alive while the app is in use.
 * START_STICKY: if the system kills it, it comes back on its own (main runs again).
 */
public class CoreService extends QtService
{
    static final String TAG = "photowagon";
    // Transitional: SyncService still holds id 1 in the activity process until the core
    // takes over the sync state; then this service carries the one notification.
    static final int NOTIFICATION_ID = 2;
    static final String EXTRA_FOREGROUND = "foreground";
    private boolean foreground;

    static boolean autosync(Context ctx)
    {
        return new File(new File(ctx.getFilesDir(), "settings"), "autosync").exists();
    }

    /**
     * Start the core, or reconcile a running one with the auto-sync setting. Idempotent: the
     * activity calls it on every start (a core Android stopped while the app sat in the
     * background comes back) and whenever auto-sync flips. The request CARRIES whether the
     * core should be in the foreground; onStartCommand — which runs for a live service too,
     * unlike onCreate — acts on it.
     */
    static void start(Context ctx)
    {
        boolean fg = autosync(ctx);
        Intent i = new Intent(ctx, CoreService.class);
        i.putExtra(EXTRA_FOREGROUND, fg);
        try
        {
            if (fg && Build.VERSION.SDK_INT >= 26)
                ctx.startForegroundService(i);
            else
                ctx.startService(i);
        }
        catch (Exception e)
        {
            // Android 12+ refuses a foreground start from the background; the next start
            // from a visible activity succeeds. Say so instead of dying.
            Log.w(TAG, "core service: cannot start now: " + e.getMessage());
        }
    }

    private void enterForeground()
    {
        if (foreground)
            return;
        try
        {
            JSONObject st = new JSONObject();
            try { st.put("standby", true); st.put("enabled", true); } catch (Exception e) { }
            Notification n = SyncService.build(this, st);
            if (Build.VERSION.SDK_INT >= 29)
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            else
                startForeground(NOTIFICATION_ID, n);
            foreground = true;
            Log.i(TAG, "core service: foreground (pid " + android.os.Process.myPid() + ")");
        }
        catch (Exception e)
        {
            // e.g. Android 12+ refusing a foreground start from the background
            Log.w(TAG, "core service: cannot enter the foreground: " + e.getMessage());
        }
    }

    private void leaveForeground()
    {
        if (!foreground)
            return;
        stopForeground(Service.STOP_FOREGROUND_REMOVE);
        foreground = false;
        Log.i(TAG, "core service: left the foreground (auto-sync off)");
    }

    @Override
    public void onCreate()
    {
        // Foreground FIRST, unconditionally: a pending startForegroundService() must be
        // answered within seconds, and super.onCreate() (QtServiceBase) loads Qt and waits for
        // the native service setup — the deadline must not depend on how long that takes, nor
        // on re-reading a setting that may have changed since the request. onStartCommand,
        // which follows at once, leaves the foreground again if this start did not ask for it.
        enterForeground();
        super.onCreate();   // QtServiceBase: load the .so, run main("-service") on Qt's thread
        Log.i(TAG, "core service: created");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId)
    {
        super.onStartCommand(intent, flags, startId);
        // The request says whether to be in the foreground; a sticky restart (null intent)
        // falls back to the setting.
        boolean fg = intent != null ? intent.getBooleanExtra(EXTRA_FOREGROUND, autosync(this)) : autosync(this);
        if (fg)
            enterForeground();
        else
            leaveForeground();
        return START_STICKY;
    }

    /**
     * Android 15+: the app's dataSync budget is spent. Leave the foreground and stop, as the
     * system requires — otherwise it crashes the process. Sync resumes the next time the app
     * starts the core.
     */
    @Override
    public void onTimeout(int startId, int fgsType)
    {
        Log.w(TAG, "core service: foreground time budget exhausted (type " + fgsType + ") — stopping");
        leaveForeground();
        stopSelf();
    }

    @Override
    public void onDestroy()
    {
        Log.i(TAG, "core service: destroyed");
        super.onDestroy();
    }
}
