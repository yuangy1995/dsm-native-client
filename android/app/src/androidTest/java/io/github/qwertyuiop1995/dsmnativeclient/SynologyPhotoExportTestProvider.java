package io.github.qwertyuiop1995.dsmnativeclient;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/** 测试APK独立进程只用平台类；真实Binder/文件描述符仅访问合成测试目录。 */
public class SynologyPhotoExportTestProvider extends ContentProvider {
    public static final String AUTHORITY = "io.github.qwertyuiop1995.dsmnativeclient.test.photoexports";
    private static class Entry {
        final String name, mime;
        final File file;
        Entry(String name, String mime, File file) { this.name = name; this.mime = mime; this.file = file; }
    }
    private final Map<String, Entry> entries = new LinkedHashMap<>();
    private int failAfter = -1;
    private int creates = 0;
    private File directory() {
        File result = new File(getContext().getCacheDir(), "synthetic-photo-exports");
        result.mkdirs(); return result;
    }
    @Override public boolean onCreate() { return true; }
    @Override public synchronized Bundle call(String method, String arg, Bundle extras) {
        if (method.equals("reset")) {
            entries.clear();
            File[] files = directory().listFiles();
            if (files != null) for (File file : files) if (file.isFile()) file.delete();
            failAfter = -1; creates = 0; return new Bundle();
        }
        if (method.equals("failAfter")) { failAfter = Integer.parseInt(arg); creates = 0; return new Bundle(); }
        // 参数名沿Android SDK DocumentsContract，范围仅本提供器的root与已创建编号。
        if (method.equals("android:createDocument")) {
            Uri parent = extras.getParcelable("uri");
            if (!DocumentsContract.getDocumentId(parent).equals("root")) throw new IllegalArgumentException("Unknown synthetic parent");
            if (failAfter >= 0 && creates++ >= failAfter) throw new IllegalStateException("Synthetic create failure");
            String requested = extras.getString(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
            String name = requested;
            int suffix = 1, dot = requested.lastIndexOf('.');
            if (dot <= 0) dot = requested.length();
            while (hasName(name)) name = requested.substring(0, dot) + " (" + suffix++ + ")" + requested.substring(dot);
            String id = UUID.randomUUID().toString();
            File file = new File(directory(), id);
            try { if (!file.createNewFile()) throw new IOException("Synthetic document exists"); }
            catch (IOException error) { throw new IllegalStateException(error); }
            entries.put(id, new Entry(name, extras.getString(DocumentsContract.Document.COLUMN_MIME_TYPE), file));
            Bundle result = new Bundle(); result.putParcelable("uri", DocumentsContract.buildDocumentUri(AUTHORITY, id)); return result;
        }
        if (method.equals("android:deleteDocument")) {
            Uri uri = extras.getParcelable("uri");
            Entry entry = entries.remove(DocumentsContract.getDocumentId(uri));
            if (entry != null) entry.file.delete();
            return new Bundle();
        }
        throw new IllegalArgumentException("Unknown synthetic operation");
    }
    private boolean hasName(String name) {
        for (Entry entry : entries.values()) if (entry.name.equals(name)) return true;
        return false;
    }
    @Override public synchronized Cursor query(Uri uri, String[] projection, String selection, String[] args, String sortOrder) {
        String[] columns = projection != null ? projection : new String[] { DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE };
        MatrixCursor result = new MatrixCursor(columns);
        boolean children = "children".equals(uri.getLastPathSegment());
        for (Map.Entry<String, Entry> pair : entries.entrySet()) {
            String id = pair.getKey(); Entry entry = pair.getValue();
            if (!children && !id.equals(DocumentsContract.getDocumentId(uri))) continue;
            Object[] row = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) {
                switch (columns[i]) {
                    case DocumentsContract.Document.COLUMN_DOCUMENT_ID: row[i] = id; break;
                    case DocumentsContract.Document.COLUMN_DISPLAY_NAME: row[i] = entry.name; break;
                    case DocumentsContract.Document.COLUMN_SIZE: row[i] = entry.file.length(); break;
                    case DocumentsContract.Document.COLUMN_MIME_TYPE: row[i] = entry.mime; break;
                    case DocumentsContract.Document.COLUMN_FLAGS: row[i] = DocumentsContract.Document.FLAG_SUPPORTS_WRITE | DocumentsContract.Document.FLAG_SUPPORTS_DELETE; break;
                    default: row[i] = null;
                }
            }
            result.addRow(row);
        }
        return result;
    }
    @Override public synchronized String getType(Uri uri) {
        Entry entry = entries.get(DocumentsContract.getDocumentId(uri)); return entry != null ? entry.mime : null;
    }
    @Override public synchronized ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        Entry entry = entries.get(DocumentsContract.getDocumentId(uri));
        if (entry == null) throw new FileNotFoundException("Missing synthetic document");
        return ParcelFileDescriptor.open(entry.file, ParcelFileDescriptor.parseMode(mode));
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
