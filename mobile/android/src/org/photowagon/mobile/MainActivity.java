package org.photowagon.mobile;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import java.io.File;
import java.io.FileWriter;
import java.nio.file.Files;

import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;

import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanner;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;

import org.qtproject.qt.android.bindings.QtActivity;

/**
 * Qt's activity plus the two things Qt cannot do for us:
 *  - ask for the photo permission (the D side then reads DCIM/ and Pictures/);
 *  - scan the pairing QR code. QML opens "pwscan://start"; Android routes that
 *    back to this activity (intent-filter, singleTop → onNewIntent), which runs
 *    the Google code scanner and drops the text into files/settings/scanned,
 *    where the D side picks it up.
 */
public class MainActivity extends QtActivity
{
    private static final String TAG = "photowagon";
    private static final int REQUEST_PHOTOS = 1;
    private static final int REQUEST_NOTIFY = 2;
    private static MainActivity instance;
    private static Handler watcher;
    private static long statusSeen;
    private static boolean notifyAsked;

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results)
    {
        super.onRequestPermissionsResult(code, perms, results);
        Log.i(TAG, "photo permission " + (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED ? "granted" : "denied"));
    }

    @Override
    public void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);
        instance = this;
        exportQtEnvironment();
        watchSyncStatus();
        // Auto-sync on → the foreground service from the very first moment, before Qt is
        // even up: it is what keeps this process off Android's cached-app freezer once the
        // screen goes off or the user leaves, so the p2p link and the pushes keep going.
        if (new File(new File(getFilesDir(), "settings"), "autosync").exists())
            SyncService.standby(getApplicationContext());
        handle(getIntent());
    }

    /**
     * QtLoader sets QT_PLUGIN_PATH, QML_IMPORT_PATH and friends with Os.setenv,
     * which the native side normally sees through getenv. Under the emulator's
     * ARM translation (Berberis) the translated libc keeps its own copy of the
     * environment taken before that, so Qt finds no platform plugin. The D side
     * reads this file and sets the variables itself (see main.d).
     */
    private void exportQtEnvironment()
    {
        try
        {
            StringBuilder sb = new StringBuilder();
            for (java.util.Map.Entry<String, String> e : System.getenv().entrySet())
                if (e.getKey().startsWith("QT") || e.getKey().startsWith("QML") || e.getKey().equals("LD_LIBRARY_PATH"))
                    sb.append(e.getKey()).append('=').append(e.getValue()).append('\n');
            File dir = new File(getFilesDir(), "settings");
            dir.mkdirs();
            FileWriter w = new FileWriter(new File(dir, "qt-env"));
            w.write(sb.toString());
            w.close();
        }
        catch (Exception e)
        {
            Log.w(TAG, "cannot export Qt environment: " + e.getMessage());
        }
    }

    @Override
    protected void onDestroy()
    {
        if (instance == this) instance = null;
        super.onDestroy();
    }

    /**
     * The D side writes files/settings/sync-status whenever the sync state changes;
     * every 2 s this reads it and keeps the notification (and the foreground service
     * that keeps the process alive) in step. Lives on the main looper for the life of
     * the process, so the notification follows the sync after the activity is gone.
     */
    private void watchSyncStatus()
    {
        if (watcher != null)
            return;
        final File file = new File(new File(getFilesDir(), "settings"), "sync-status");
        final Context app = getApplicationContext();
        watcher = new Handler(Looper.getMainLooper());
        watcher.post(new Runnable() {
            public void run()
            {
                try
                {
                    long m = file.lastModified();
                    if (m != 0 && m != statusSeen)
                    {
                        statusSeen = m;
                        JSONObject st = new JSONObject(new String(Files.readAllBytes(file.toPath()), "UTF-8"));
                        if (st.optBoolean("active", false) && !notifyAsked && Build.VERSION.SDK_INT >= 33 && instance != null
                                && instance.checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED)
                        {
                            notifyAsked = true;
                            instance.requestPermissions(new String[] { "android.permission.POST_NOTIFICATIONS" }, REQUEST_NOTIFY);
                        }
                        SyncService.update(app, st);
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
     * Asked by the D side (pwperm://request) once the window is up. Asking in
     * onCreate put the system dialog over Qt's very first frame, and the window
     * came back black: Qt never got exposed again until the app was restarted.
     */
    private void requestPhotos()
    {
        // On Android 13+ photos and videos are separate permissions: ask for both, or the
        // camera's videos stay invisible to the scan (they need READ_MEDIA_VIDEO).
        String[] permissions = Build.VERSION.SDK_INT >= 33
            ? new String[] { "android.permission.READ_MEDIA_IMAGES", "android.permission.READ_MEDIA_VIDEO" }
            : new String[] { "android.permission.READ_EXTERNAL_STORAGE" };
        boolean needAsk = false;
        for (String p : permissions)
            if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED)
                needAsk = true;
        if (needAsk)
            requestPermissions(permissions, REQUEST_PHOTOS);
    }

    @Override
    protected void onNewIntent(Intent intent)
    {
        super.onNewIntent(intent);
        handle(intent);
    }

    private void handle(Intent intent)
    {
        if (intent == null)
            return;
        Uri uri = intent.getData();
        if (uri == null)
            return;
        if ("pwscan".equals(uri.getScheme()))
            startScan();
        else if ("pwperm".equals(uri.getScheme()))
            requestPhotos();
        else if ("pw".equals(uri.getScheme()))
            save(uri.toString());   // a pairing code opened as a link (or sent by adb): same path as the QR
    }

    private void startScan()
    {
        GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .build();
        GmsBarcodeScanner scanner = GmsBarcodeScanning.getClient(this, options);
        scanner.startScan()
            .addOnSuccessListener(barcode -> save(barcode.getRawValue()))
            .addOnFailureListener(e -> Log.w(TAG, "scan failed: " + e.getMessage()))
            .addOnCanceledListener(() -> Log.i(TAG, "scan cancelled"));
    }

    private void save(String value)
    {
        if (value == null)
            return;
        try
        {
            File dir = new File(getFilesDir(), "settings");
            dir.mkdirs();
            FileWriter w = new FileWriter(new File(dir, "scanned"));
            w.write(value);
            w.close();
            Log.i(TAG, "scanned code saved");
        }
        catch (Exception e)
        {
            Log.w(TAG, "cannot save scanned code: " + e.getMessage());
        }
    }
}
