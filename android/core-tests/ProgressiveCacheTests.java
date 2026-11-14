package studio.sonora.android;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

public final class ProgressiveCacheTests {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("sonora-progressive-test-");
        ExecutorService executor = Executors.newSingleThreadExecutor();
        byte[] data = "0123456789".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        File destination = directory.resolve("song.mp3").toFile();
        try {
            try (ProgressiveCache cache = new ProgressiveCache(destination, data.length, Core.hash(data))) {
                cache.append(data, 0, 3);
                byte[] result = new byte[10];
                if (cache.readAt(0, result, 0, result.length) != 3 || destination.exists()) throw new AssertionError("prefix must be readable before full download and promotion");
                Future<Integer> delayed = executor.submit(() -> cache.readAt(8, result, 0, 2));
                try { delayed.get(100, TimeUnit.MILLISECONDS); throw new AssertionError("unavailable seek must wait"); }
                catch (TimeoutException expected) { }
                cache.append(data, 3, 7);
                if (delayed.get(2, TimeUnit.SECONDS) != 2 || result[0] != '8' || result[1] != '9') throw new AssertionError("seek must resume when bytes arrive");
                cache.finish();
                if (!Arrays.equals(data, Files.readAllBytes(destination.toPath()))) throw new AssertionError("verified download must be cached");
                if (cache.readAt(data.length, result, 0, 1) != -1) throw new AssertionError("end of file");
            }
            File invalid = directory.resolve("invalid.mp3").toFile();
            try (ProgressiveCache cache = new ProgressiveCache(invalid, data.length, Core.hash(new byte[]{1}))) {
                cache.append(data, 0, data.length);
                try { cache.finish(); throw new AssertionError("invalid hash must fail"); } catch (IOException expected) { }
                if (invalid.exists()) throw new AssertionError("invalid data must never become offline cache");
            }
            try (ProgressiveCache cache = new ProgressiveCache(directory.resolve("cancel.mp3").toFile(), data.length, Core.hash(data))) {
                Future<Boolean> waiting = executor.submit(() -> { try { cache.readAt(1, new byte[1], 0, 1); return false; } catch (IOException expected) { return true; } });
                cache.fail(new IOException("cancelled"));
                if (!waiting.get(2, TimeUnit.SECONDS)) throw new AssertionError("cancellation must wake blocked reader");
            }
            try (ProgressiveCache cache = new ProgressiveCache(directory.resolve("reader-cancel.mp3").toFile(), data.length, Core.hash(data))) {
                java.util.concurrent.atomic.AtomicBoolean closed = new java.util.concurrent.atomic.AtomicBoolean();
                Future<Boolean> waiting = executor.submit(() -> { try { cache.readAt(1, new byte[1], 0, 1, closed::get); return false; } catch (InterruptedIOException expected) { return true; } });
                closed.set(true); cache.wakeReaders();
                if (!waiting.get(2, TimeUnit.SECONDS)) throw new AssertionError("reader close must unblock without cancelling background download");
                cache.append(data, 0, data.length); cache.finish();
                if (!Files.exists(directory.resolve("reader-cancel.mp3"))) throw new AssertionError("closed reader must not stop caching");
            }
            try (java.util.stream.Stream<Path> paths = Files.list(directory)) {
                if (paths.anyMatch(path -> path.toString().endsWith(".part"))) throw new AssertionError("temporary files must be cleaned");
            }
            System.out.println("Progressive cache checks passed: early read, seek waiting, verification, failure and cleanup");
        } finally {
            executor.shutdownNow();
            try (java.util.stream.Stream<Path> paths = Files.list(directory)) { for (Path path : (Iterable<Path>)paths::iterator) Files.delete(path); }
            Files.delete(directory);
        }
    }
}
