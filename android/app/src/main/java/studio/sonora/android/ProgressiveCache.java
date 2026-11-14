package studio.sonora.android;

import java.io.*;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Sequential writer and blocking random-access reader for an unverified audio download. */
final class ProgressiveCache implements Closeable {
    private final File destination, temporary;
    private final RandomAccessFile file;
    private final long expectedSize;
    private final String expectedHash;
    private final MessageDigest hash;
    private long available;
    private boolean completed, closed;
    private IOException failure;

    ProgressiveCache(File destination, long expectedSize, String expectedHash) throws IOException {
        if (expectedSize <= 0 || expectedSize > Core.MAX_AUDIO || !expectedHash.matches("[0-9a-f]{64}")) throw new IOException("歌曲信息无效");
        File parent = destination.getParentFile();
        if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("无法创建离线存储目录");
        this.destination = destination; this.expectedSize = expectedSize; this.expectedHash = expectedHash;
        try { hash = MessageDigest.getInstance("SHA-256"); } catch (NoSuchAlgorithmException error) { throw new AssertionError(error); }
        temporary = File.createTempFile("progressive-", ".part", parent);
        try { file = new RandomAccessFile(temporary, "rw"); }
        catch (IOException error) { temporary.delete(); throw error; }
    }

    synchronized void append(byte[] bytes, int offset, int length) throws IOException {
        ensureOpen();
        if (completed || failure != null) throw new IOException("下载已经结束");
        if (length < 0 || offset < 0 || offset > bytes.length - length || length > expectedSize - available) throw new IOException("下载文件大小不符");
        file.seek(available); file.write(bytes, offset, length); hash.update(bytes, offset, length);
        available += length; notifyAll();
    }

    synchronized int readAt(long position, byte[] output, int offset, int length) throws IOException {
        return readAt(position, output, offset, length, () -> false);
    }

    synchronized int readAt(long position, byte[] output, int offset, int length, java.util.function.BooleanSupplier cancelled) throws IOException {
        if (position < 0 || length < 0 || offset < 0 || offset > output.length - length) throw new IOException("读取范围无效");
        if (length == 0) return 0;
        while (!closed && !cancelled.getAsBoolean() && failure == null && position >= available && !completed && position < expectedSize) {
            try { wait(); } catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new InterruptedIOException(); }
        }
        ensureOpen();
        if (cancelled.getAsBoolean()) throw new InterruptedIOException("读取已取消");
        if (failure != null) throw failure;
        if (position >= available) return -1;
        int count = (int)Math.min((long)length, available - position);
        file.seek(position); file.readFully(output, offset, count); return count;
    }

    synchronized void finish() throws IOException {
        ensureOpen();
        if (completed || failure != null) throw new IOException("下载已经结束");
        if (available != expectedSize || !Core.hex(hash.digest()).equals(expectedHash)) {
            fail(new IOException("歌曲下载不完整，请重试")); throw failure;
        }
        try {
            file.getFD().sync();
            Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            completed = true; notifyAll();
        } catch (IOException error) { fail(error); throw error; }
    }

    synchronized boolean contains(long position) throws IOException {
        ensureOpen(); if (failure != null) throw failure; return position < available;
    }
    synchronized void wakeReaders() { notifyAll(); }

    synchronized void fail(IOException error) {
        if (!completed && failure == null) failure = error;
        notifyAll();
    }

    private void ensureOpen() throws IOException { if (closed) throw new IOException("缓存已关闭"); }
    @Override public synchronized void close() throws IOException {
        if (closed) return;
        closed = true; notifyAll();
        try { file.close(); } finally { Files.deleteIfExists(temporary.toPath()); }
    }
}
