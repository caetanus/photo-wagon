package org.photowagon.mobile;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import java.nio.file.Files;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
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
 * Foreground only while there is background work to keep going — auto-sync on (the
 * settings/autosync flag; the sync state the core writes follows it). It carries the app's one
 * notification — the sync's progress — and holds a partial wake lock while a photo is going
 * (5c: both moved here from the UI process's old SyncService). A foreground service keeps the
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
    static final String CHANNEL = "sync";
    static final int NOTIFICATION_ID = 1;   // the sync's progress, while in the foreground
    static final int SUMMARY_ID = 3;        // what the last sync did, after auto-sync went off
    static final String EXTRA_FOREGROUND = "foreground";
    private boolean foreground;
    private JSONObject lastStatus;          // the sync state the core last wrote
    private Handler watcher;
    private long statusSeen;
    private PowerManager.WakeLock wakeLock;
    private long refusedAt;                 // elapsedRealtime of the last refused foreground start

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
            JSONObject st = lastStatus;
            if (st == null)
            {
                st = new JSONObject();
                try { st.put("standby", true); st.put("enabled", true); } catch (Exception e) { }
            }
            Notification n = build(this, st);
            if (Build.VERSION.SDK_INT >= 29)
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            else
                startForeground(NOTIFICATION_ID, n);
            foreground = true;
            refusedAt = 0;
            Log.i(TAG, "core service: foreground (pid " + android.os.Process.myPid() + ")");
            // syncing again: the old summary is moot; a transfer already going gets the CPU
            ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE)).cancel(SUMMARY_ID);
            holdCpu(lastStatus != null && lastStatus.optBoolean("active", false));
        }
        catch (Exception e)
        {
            // e.g. Android 12+ refusing a foreground start from the background
            refusedAt = android.os.SystemClock.elapsedRealtime();
            Log.w(TAG, "core service: cannot enter the foreground: " + e.getMessage());
        }
    }

    private void leaveForeground()
    {
        if (!foreground)
            return;
        stopForeground(Service.STOP_FOREGROUND_REMOVE);
        holdCpu(false);   // no foreground, no reason to keep the CPU up
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
        watchSyncStatus();
        // off the main thread: a first-install copy of 120 MB must not hold onCreate (the
        // service-execution timeout); the core waits for the files to appear
        Thread x = new Thread(this::extractModels, "extract-models");
        x.setDaemon(true);
        x.start();
        super.onCreate();   // QtServiceBase: load the .so, run main("-service") on Qt's thread
        Log.i(TAG, "core service: created");
    }

    /**
     * The on-device face models ship as APK assets; the core reads them as files. Qt's
     * "assets:/" file engine comes with the Android platform plugin, which this windowless
     * service process does not load — so they are copied out here, once, atomically (a temp
     * file renamed into place: the core never sees half of one).
     */
    private void extractModels()
    {
        File dir = new File(getFilesDir(), "models");
        dir.mkdirs();
        for (String name : new String[] { "yunet.tflite", "r100.tflite" })
        {
            File out = new File(dir, name);
            if (out.exists())
                continue;
            File tmp = new File(dir, name + ".tmp-java");
            try (InputStream in = getAssets().open("models/" + name);
                 OutputStream os = new FileOutputStream(tmp))
            {
                byte[] buf = new byte[1 << 16];
                for (int n; (n = in.read(buf)) > 0; )
                    os.write(buf, 0, n);
            }
            catch (Exception e)
            {
                Log.w(TAG, "core service: cannot extract " + name + ": " + e.getMessage());
                tmp.delete();
                continue;
            }
            if (!tmp.renameTo(out))
                tmp.delete();
            else
                Log.i(TAG, "core service: extracted " + name);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId)
    {
        super.onStartCommand(intent, flags, startId);
        // A startForegroundService() request must be answered with startForeground() —
        // even when the setting flipped since it was sent; the setting as it is NOW then
        // decides (a request may be older than the auto-sync switch the watcher already saw).
        if (intent != null && intent.getBooleanExtra(EXTRA_FOREGROUND, false))
            enterForeground();
        reconcileForeground();
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
        if (watcher != null)
            watcher.removeCallbacksAndMessages(null);
        holdCpu(false);
        super.onDestroy();
    }

    // ---- the sync's notification and wake lock (5c: they live where the sync runs) --------

    /**
     * The core writes files/settings/sync-status (atomically) whenever the sync state changes;
     * every 2 s this reads it and keeps the notification, the wake lock and the foreground in
     * step: foreground while auto-sync is on, the CPU held only while a photo is going.
     */
    private void watchSyncStatus()
    {
        final File file = new File(new File(getFilesDir(), "settings"), "sync-status");
        watcher = new Handler(Looper.getMainLooper());
        watcher.post(new Runnable() {
            public void run()
            {
                try
                {
                    reconcileForeground();   // every tick, whatever the status file says
                    long m = file.lastModified();
                    if (m != 0 && m != statusSeen)
                    {
                        statusSeen = m;
                        applyStatus(new JSONObject(new String(Files.readAllBytes(file.toPath()), "UTF-8")));
                    }
                }
                catch (Exception e)
                {
                    Log.w(TAG, "sync status: " + e.getMessage());
                }
                watcher.postDelayed(this, 2000);
            }
        });
    }

    /**
     * Foreground exactly while auto-sync is on — or while a one-time "Send all now" run the
     * core reports (status "manual") is going. The settings/autosync flag is read now, on
     * every tick and every start request, so no stale request can leave the service on the
     * wrong side.
     */
    private void reconcileForeground()
    {
        // auto-sync on, or a one-time "Send all now" run still going
        boolean want = autosync(this) || (lastStatus != null && lastStatus.optBoolean("manual", false));
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (want && !foreground)
        {
            // refused before (Android 12+ from the background): try again at most once a
            // minute; the next start from a visible activity gets it at once
            if (refusedAt != 0 && android.os.SystemClock.elapsedRealtime() - refusedAt < 60_000)
                return;
            enterForeground();
        }
        else if (!want && foreground)
            leaveForeground();
    }

    private void applyStatus(JSONObject st)
    {
        lastStatus = st;
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        reconcileForeground();
        if (foreground)
            nm.notify(NOTIFICATION_ID, build(this, st));
        else if (st.optInt("failed", 0) > 0 || st.optInt("sent", 0) > 0)
        {
            // auto-sync is off: a dismissible summary under its own id (the foreground one is
            // being cancelled asynchronously and would take a replacement with it), never a
            // progress bar — and kept current while the last transfer winds down
            JSONObject sum = new JSONObject();
            try
            {
                sum.put("enabled", false);
                sum.put("active", false);
                sum.put("sent", st.optInt("sent", 0));
                sum.put("failed", st.optInt("failed", 0));
            }
            catch (Exception e) { }
            nm.notify(SUMMARY_ID, build(this, sum));
        }
        holdCpu(foreground && st.optBoolean("active", false));
    }

    /** CPU on while a photo is actually going; off in standby, so waiting costs nothing. */
    private void holdCpu(boolean on)
    {
        try
        {
            if (on)
            {
                if (wakeLock == null)
                {
                    PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                    wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "photowagon:sync");
                    wakeLock.setReferenceCounted(false);
                }
                if (!wakeLock.isHeld())
                    wakeLock.acquire();
            }
            else if (wakeLock != null && wakeLock.isHeld())
                wakeLock.release();
        }
        catch (Exception e)
        {
            Log.w(TAG, "core service: wake lock: " + e.getMessage());
        }
    }

    static Notification build(Context ctx, JSONObject st)
    {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null)
        {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Sending photos", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("Progress of the photos going to the computer");
            nm.createNotificationChannel(ch);
        }
        boolean enabled = st.optBoolean("enabled", true);
        boolean active = st.optBoolean("active", false);
        boolean connected = st.optBoolean("connected", false);
        int total = st.optInt("total", 0), done = st.optInt("done", 0);
        int pending = st.optInt("pending", 0), failed = st.optInt("failed", 0), sent = st.optInt("sent", 0);
        String title, text;
        if (active)
        {
            title = "Sending photos to the computer";
            text = (done + 1) + " of " + total + (failed > 0 ? " · " + failed + " failed" : "");
        }
        else if (enabled && !connected && pending > 0)
        {
            title = pending + " photos waiting for the computer";
            text = "They go as soon as it is reachable";
        }
        else if (enabled && !connected)
        {
            title = "Looking for the computer";
            text = "New photos go over as soon as it answers";
        }
        else if (enabled && (st.optBoolean("standby", false) || sent + failed == 0))
        {
            title = "In touch with the computer";
            text = "New photos go over as they appear";
        }
        else
        {
            title = failed > 0 ? "Some photos did not go" : "Photos are on the computer";
            text = sent + " sent" + (failed > 0 ? ", " + failed + " failed" : "");
        }
        Intent open = new Intent(ctx, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(ctx, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, CHANNEL) : new Notification.Builder(ctx);
        b.setSmallIcon(R.drawable.ic_notification)
         .setContentTitle(title)
         .setContentText(text)
         .setContentIntent(pi)
         .setOngoing(enabled)
         .setOnlyAlertOnce(true);
        if (active && total > 0)
            b.setProgress(total, done, false);
        return b.build();
    }
}
