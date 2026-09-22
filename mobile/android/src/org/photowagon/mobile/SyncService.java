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
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import org.json.JSONObject;

/**
 * The foreground service that keeps the sync alive when the app is not on screen.
 *
 * Android 12+ freezes a "cached" process (no visible activity, no foreground service)
 * within seconds of the screen going off: every thread stops, the p2p link dies, and
 * nothing syncs until the app is opened again. A foreground service exempts the
 * process from the freezer and, while a photo is actually going, a partial wake lock
 * keeps the CPU up for the transfer. So this service runs for as long as auto-sync
 * is enabled — "standby" from MainActivity.onCreate, before Qt even starts — and its
 * notification follows the sync state the D side writes to files/settings/sync-status
 * (MainActivity watches that file and calls update()). Nothing here talks to D.
 */
public class SyncService extends Service
{
    static final String TAG = "photowagon";
    static final String CHANNEL = "sync";
    static final int NOTIFICATION_ID = 1;
    private static boolean running;
    private static SyncService instance;
    private PowerManager.WakeLock wakeLock;

    /** Start the service with no sync in flight yet: the process must stay alive to find the computer. */
    static void standby(Context ctx)
    {
        JSONObject st = new JSONObject();
        try { st.put("standby", true); st.put("enabled", true); } catch (Exception e) { }
        start(ctx, st);
    }

    private static void start(Context ctx, JSONObject st)
    {
        Intent i = new Intent(ctx, SyncService.class);
        i.putExtra("status", st.toString());
        try
        {
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i); else ctx.startService(i);
        }
        catch (Exception e)
        {
            // Android 12+ refuses a foreground start from the background (we were started by
            // something other than the user, with the screen off); the next status change
            // from a visible app starts it. Say so instead of dying.
            Log.w(TAG, "sync service: cannot start now: " + e.getMessage());
        }
    }

    /** The D side changed the sync state: keep the service and its notification in step. */
    static void update(Context ctx, JSONObject st)
    {
        boolean enabled = st.optBoolean("enabled", true);
        boolean active = st.optBoolean("active", false);
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (!enabled)
        {
            // auto-sync turned off: nothing to keep alive; leave a summary if there is one
            if (running)
                ctx.stopService(new Intent(ctx, SyncService.class));
            else if (st.optInt("failed", 0) > 0 || st.optInt("sent", 0) > 0)
                nm.notify(NOTIFICATION_ID, build(ctx, st));
            return;
        }
        if (!running)
        {
            start(ctx, st);
            return;
        }
        nm.notify(NOTIFICATION_ID, build(ctx, st));
        if (instance != null)
            instance.holdCpu(active);
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
            Log.w(TAG, "sync service: wake lock: " + e.getMessage());
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId)
    {
        running = true;
        instance = this;
        JSONObject st = new JSONObject();
        try { st = new JSONObject(intent.getStringExtra("status")); } catch (Exception e) { }
        Notification n = build(this, st);
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        else
            startForeground(NOTIFICATION_ID, n);
        holdCpu(st.optBoolean("active", false));
        // Sticky: if Android reclaims the process under pressure it restarts the service (and
        // with it the process, whose main() brings the D side back up — see MainActivity).
        return START_STICKY;
    }

    @Override
    public void onDestroy()
    {
        holdCpu(false);
        running = false;
        if (instance == this)
            instance = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
