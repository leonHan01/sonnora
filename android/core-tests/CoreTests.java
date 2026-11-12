package studio.sonora.android;

import java.io.*;
import java.nio.file.*;
import java.util.*;

public final class CoreTests {
    private static int checks;
    private static void check(boolean condition, String description) { checks++; if (!condition) throw new AssertionError(description); }
    public static void main(String[] args) throws Exception {
        for (String valid : Arrays.asList("https://121.40.254.112", "https://example.test/", "http://localhost:8080", "http://10.0.2.2:8080")) check(Core.server(valid).startsWith("http"), "Valid server accepted");
        for (String invalid : Arrays.asList("http://example.test", "https://user:token@example.test", "https://example.test?token=secret", "https://example.test/api", "file:///tmp/audio", "https://example.test/#secret")) {
            boolean rejected = false; try { Core.server(invalid); } catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected, "Unsafe server rejected");
        }
        check(Core.server("https://EXAMPLE.test/").equals("https://example.test"), "Canonical server identity");
        String id = UUID.randomUUID().toString();
        check(Core.songKey("https://one.test", id).equals(Core.songKey("https://one.test", id.toUpperCase(Locale.ROOT))), "Stable remote identity");
        check(!Core.songKey("https://one.test", id).equals(Core.songKey("https://two.test", id)), "Server identities isolated");
        check(Core.nextIndex(0, 0, Core.Mode.LOOP, true, new Random(1)) == -1, "Empty queue stops");
        check(Core.nextIndex(3, 2, Core.Mode.SEQUENTIAL, true, new Random(1)) == -1, "Sequential end stops");
        check(Core.nextIndex(3, 2, Core.Mode.LOOP, true, new Random(1)) == 0, "List loops");
        check(Core.nextIndex(3, 1, Core.Mode.REPEAT, true, new Random(1)) == 1, "Automatic repeat one");
        check(Core.nextIndex(3, 1, Core.Mode.REPEAT, false, new Random(1)) == 2, "Manual next escapes repeat");
        for (int i = 0; i < 100; i++) check(Core.nextIndex(3, 1, Core.Mode.SHUFFLE, true, new Random(i)) != 1, "Shuffle does not immediately repeat");
        check(Core.different(Arrays.asList("one", "two"), "one", new Random(1)).equals("two"), "Offline radio avoids prior song");
        check(Core.different(Collections.singletonList("one"), "one", new Random(1)).equals("one"), "Single-song radio keeps playing");
        check(Core.different(Collections.emptyList(), "one", new Random(1)) == null, "Empty radio handled");
        Path directory = Files.createTempDirectory("sonora-cache-tests-");
        try {
            byte[] payload = "A complete generated audio payload".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            File output = directory.resolve("audio.mp3").toFile();
            try (InputStream input = new ByteArrayInputStream(payload)) { Core.cache(input, output, payload.length, Core.hash(payload), null); }
            check(Arrays.equals(Files.readAllBytes(output.toPath()), payload), "Verified bytes persisted");
            for (int scenario = 0; scenario < 3; scenario++) {
                boolean rejected = false;
                byte[] bytes = scenario == 0 ? Arrays.copyOf(payload, payload.length - 1) : payload;
                String hash = scenario == 1 ? String.join("", Collections.nCopies(64, "0")) : Core.hash(payload);
                try (InputStream input = new ByteArrayInputStream(bytes)) {
                    if (scenario == 2) Thread.currentThread().interrupt();
                    Core.cache(input, output, payload.length, hash, null);
                } catch (IOException expected) { rejected = true; }
                finally { Thread.interrupted(); }
                check(rejected, "Incomplete, corrupt, cancelled download rejected");
                check(Arrays.equals(Files.readAllBytes(output.toPath()), payload), "Failure keeps previous cache intact");
            }
            try (java.util.stream.Stream<Path> files = Files.list(directory)) { check(files.noneMatch(path -> path.toString().endsWith(".part")), "Temporary files cleaned"); }
        } finally { try (java.util.stream.Stream<Path> paths = Files.walk(directory)) { paths.sorted(Comparator.reverseOrder()).forEach(path -> { try { Files.delete(path); } catch (IOException ignored) {} }); } }
        check(Core.time(3661000).equals("1:01:01"), "Long duration formatting");
        System.out.println(checks + " Android core checks passed; no device or window started.");
    }
}
