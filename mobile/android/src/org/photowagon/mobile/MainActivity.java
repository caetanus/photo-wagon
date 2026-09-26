package org.photowagon.mobile;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.core.content.FileProvider;

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
    private static final int REQUEST_DELETE = 3;
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
        handle(getIntent());
    }

    @Override
    protected void onStart()
    {
        super.onStart();
        // The core's own process (":core") keeps running when this activity goes away. Started
        // (or reconciled) on EVERY start, not only onCreate: a core Android stopped while the
        // app sat in the background must come back when the user returns to the activity.
        CoreService.start(getApplicationContext());
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
     * Hand a photo file to the Android share sheet (WhatsApp, email, …) via ACTION_SEND.
     * Called from D (localbridge) through the videothumb JNI shim. The file is exposed
     * with the Qt FileProvider (authority ${applicationId}.qtprovider, whose paths cover
     * both app storage and external storage), and we post to the UI thread because the
     * D caller may be on a worker fiber.
     */
    public static void shareImage(final String path, final String mime)
    {
        final MainActivity a = instance;
        if (a == null || path == null || path.isEmpty()) return;
        a.runOnUiThread(new Runnable() {
            public void run() {
                try {
                    // one path, or several one per line (a selection): ACTION_SEND_MULTIPLE
                    String[] paths = path.split("\n");
                    java.util.ArrayList<Uri> uris = new java.util.ArrayList<Uri>();
                    for (String p : paths)
                        if (!p.isEmpty())
                            uris.add(FileProvider.getUriForFile(a, a.getPackageName() + ".qtprovider", new File(p)));
                    if (uris.isEmpty()) return;
                    Intent send;
                    if (uris.size() == 1) {
                        send = new Intent(Intent.ACTION_SEND);
                        send.putExtra(Intent.EXTRA_STREAM, uris.get(0));
                    } else {
                        send = new Intent(Intent.ACTION_SEND_MULTIPLE);
                        send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
                    }
                    send.setType((mime == null || mime.isEmpty()) ? "image/*" : mime);
                    send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    Intent chooser = Intent.createChooser(send, uris.size() == 1 ? "Share photo" : "Share " + uris.size() + " photos");
                    chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    a.startActivity(chooser);
                } catch (Exception e) {
                    Log.e(TAG, "share failed: " + e);
                }
            }
        });
    }

    /**
     * The core writes files/settings/sync-status whenever the sync state changes. The
     * notification, the wake lock and the foreground follow it in CoreService (the core's
     * process); this only asks for the notification permission — which needs an activity —
     * the first time a photo is going.
     */
    private void watchSyncStatus()
    {
        if (watcher != null)
            return;
        final File file = new File(new File(getFilesDir(), "settings"), "sync-status");
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
                        // ask while there is sending to show: a run going, automatic sending on,
                        // or photos waiting — the sending itself happens in the background (the
                        // core's service), rarely while this screen is up, so "active" alone
                        // almost never met the user
                        boolean sending = st.optBoolean("active", false) || st.optBoolean("enabled", false)
                            || st.optInt("pending", 0) > 0;
                        if (sending && !notifyAsked && Build.VERSION.SDK_INT >= 33 && instance != null
                                && instance.checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED)
                        {
                            notifyAsked = true;
                            instance.requestPermissions(new String[] { "android.permission.POST_NOTIFICATIONS" }, REQUEST_NOTIFY);
                        }

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
        else if ("pwcore".equals(uri.getScheme()))
            CoreService.start(this);   // the UI lost the core and it did not come back: start it
        else if ("pwback".equals(uri.getScheme()))
            moveTaskToBack(true);      // Back at the top of the app: leave it, keep it alive
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

    /**
     * "Free up space": delete these files (one per line: path, size, mtime ms, tab-separated
     * — the phone's photos the computer confirmed it holds). They go in batches of at most
     * 2000 (createDeleteRequest refuses more), one system confirmation each, the next after
     * the user has answered the previous one. Right before each batch's request its files are
     * checked again (a file that differs from what was confirmed — edited or replaced while
     * an earlier dialog waited — is left alone) and looked up in the MediaStore (images and
     * videos). Nothing is deleted without the system dialog. Called from D (uiadapter)
     * through the videothumb JNI shim; posted to the UI thread. Android 11+ only.
     */
    public static void deleteMedia(final String paths)
    {
        final MainActivity a = instance;
        if (a == null || paths == null || paths.isEmpty()) return;
        if (Build.VERSION.SDK_INT < 30)
        {
            Log.w(TAG, "free up space: needs Android 11 (MediaStore.createDeleteRequest)");
            return;
        }
        a.runOnUiThread(new Runnable() {
            public void run() {
                try {
                    java.util.ArrayList<String[]> all = new java.util.ArrayList<String[]>();
                    for (String line : paths.split("\n")) {
                        String[] f = line.split("\t");
                        if (f.length == 3 && !f[0].isEmpty()) all.add(f);
                    }
                    deleteBatches.clear();
                    for (int from = 0; from < all.size(); from += 2000)
                        deleteBatches.add(new java.util.ArrayList<String[]>(all.subList(from, Math.min(all.size(), from + 2000))));
                    Log.i(TAG, "free up space: " + all.size() + " files in " + deleteBatches.size() + " batch(es)");
                    nextDeleteBatch(a);
                } catch (Exception e) {
                    deleteBatches.clear();
                    Log.e(TAG, "free up space failed: " + e);
                }
            }
        });
    }

    // what is still to be asked: {path, size, mtime ms} per file (UI thread only)
    private static final java.util.ArrayList<java.util.ArrayList<String[]>> deleteBatches = new java.util.ArrayList<java.util.ArrayList<String[]>>();

    /** The next batch: checked again now, found in the MediaStore, then the system dialog. */
    private static void nextDeleteBatch(MainActivity a)
    {
        while (!deleteBatches.isEmpty()) {
            java.util.ArrayList<String[]> batch = deleteBatches.remove(0);
            try {
                java.util.List<String> keep = new java.util.ArrayList<String>();
                int changed = 0;
                for (String[] f : batch) {
                    File file = new File(f[0]);
                    long size = Long.parseLong(f[1]), mtime = Long.parseLong(f[2]);
                    if (!file.isFile() || file.length() != size || file.lastModified() != mtime) { changed++; continue; }
                    keep.add(f[0]);
                }
                if (changed > 0) Log.i(TAG, "free up space: " + changed + " files changed since they were confirmed, kept");
                java.util.ArrayList<Uri> uris = new java.util.ArrayList<Uri>();
                Uri[] collections = {
                    android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                };
                android.content.ContentResolver cr = a.getContentResolver();
                for (Uri coll : collections)
                    for (int from = 0; from < keep.size(); from += 500) {
                        java.util.List<String> chunk = keep.subList(from, Math.min(keep.size(), from + 500));
                        StringBuilder sel = new StringBuilder(android.provider.MediaStore.MediaColumns.DATA + " IN (");
                        for (int k = 0; k < chunk.size(); k++) sel.append(k == 0 ? "?" : ",?");
                        sel.append(')');
                        android.database.Cursor c = cr.query(coll,
                            new String[] { android.provider.MediaStore.MediaColumns._ID },
                            sel.toString(), chunk.toArray(new String[0]), null);
                        if (c == null) continue;
                        try {
                            while (c.moveToNext())
                                uris.add(android.content.ContentUris.withAppendedId(coll, c.getLong(0)));
                        } finally {
                            c.close();
                        }
                    }
                Log.i(TAG, "free up space: " + keep.size() + " files checked, " + uris.size() + " found in the MediaStore");
                if (uris.isEmpty()) continue;   // nothing of this batch to ask: the next one
                android.app.PendingIntent pi = android.provider.MediaStore.createDeleteRequest(cr, uris);
                a.startIntentSenderForResult(pi.getIntentSender(), REQUEST_DELETE, null, 0, 0, 0);
                return;   // onActivityResult goes on
            } catch (Exception e) {
                deleteBatches.clear();
                Log.e(TAG, "free up space failed: " + e);
                return;
            }
        }
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data)
    {
        super.onActivityResult(code, result, data);
        if (code == REQUEST_DELETE)
        {
            Log.i(TAG, "free up space: " + (result == RESULT_OK ? "deleted" : "declined"));
            if (result == RESULT_OK) nextDeleteBatch(this);
            else deleteBatches.clear();   // declined: the rest is not asked either
        }
    }
}
