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

import org.json.JSONObject;

/**
 * The "Photo Wagon is sending your photos" notification, and the foreground
 * service behind it so Android keeps the process alive (and unfrozen) while
 * the D side uploads. The D side writes files/settings/sync-status (JSON);
 * MainActivity watches that file and calls update(); nothing here talks to D.
 */
public class SyncService extends Service
{
    static final String CHANNEL = "sync";
    static final int NOTIFICATION_ID = 1;
    private static boolean running;

    static void update(Context ctx, JSONObject st)
    {
        boolean active = st.optBoolean("active", false);
        if (active && !running)
        {
            Intent i = new Intent(ctx, SyncService.class);
            i.putExtra("status", st.toString());
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i); else ctx.startService(i);
            return;
        }
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (active)
            nm.notify(NOTIFICATION_ID, build(ctx, st));
        else if (running)
            ctx.stopService(new Intent(ctx, SyncService.class));
        else if (st.optInt("failed", 0) > 0 || st.optInt("sent", 0) > 0)
            nm.notify(NOTIFICATION_ID, build(ctx, st)); // the summary stays after the service went
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
        boolean active = st.optBoolean("active", false);
        int total = st.optInt("total", 0), done = st.optInt("done", 0);
        int pending = st.optInt("pending", 0), failed = st.optInt("failed", 0), sent = st.optInt("sent", 0);
        String title, text;
        if (active)
        {
            title = "Sending photos to the computer";
            text = (done + 1) + " of " + total + (failed > 0 ? " · " + failed + " failed" : "");
        }
        else if (!st.optBoolean("connected", false) && pending > 0)
        {
            title = pending + " photos waiting for the computer";
            text = "They go as soon as it is reachable";
        }
        else
        {
            title = failed > 0 ? "Some photos did not go" : "Photos are on the computer";
            text = sent + " sent" + (failed > 0 ? ", " + failed + " failed" : "");
        }
        Intent open = new Intent(ctx, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(ctx, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, CHANNEL) : new Notification.Builder(ctx);
        b.setSmallIcon(R.mipmap.ic_launcher)
         .setContentTitle(title)
         .setContentText(text)
         .setContentIntent(pi)
         .setOngoing(active)
         .setOnlyAlertOnce(true);
        if (active && total > 0)
            b.setProgress(total, done, false);
        return b.build();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId)
    {
        running = true;
        JSONObject st = new JSONObject();
        try { st = new JSONObject(intent.getStringExtra("status")); } catch (Exception e) { }
        Notification n = build(this, st);
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        else
            startForeground(NOTIFICATION_ID, n);
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy()
    {
        running = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
