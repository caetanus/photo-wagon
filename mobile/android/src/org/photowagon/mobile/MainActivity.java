package org.photowagon.mobile;

import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import java.io.File;
import java.io.FileWriter;

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
        handle(getIntent());
    }

    /**
     * Asked by the D side (pwperm://request) once the window is up. Asking in
     * onCreate put the system dialog over Qt's very first frame, and the window
     * came back black: Qt never got exposed again until the app was restarted.
     */
    private void requestPhotos()
    {
        String permission = Build.VERSION.SDK_INT >= 33
            ? "android.permission.READ_MEDIA_IMAGES"
            : "android.permission.READ_EXTERNAL_STORAGE";
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[] { permission }, REQUEST_PHOTOS);
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
