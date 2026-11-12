package studio.sonora.android;

import java.io.*;
import java.net.URI;
import java.nio.file.*;
import java.security.*;
import java.util.*;

/** Small platform-free rules shared by the app and command-line regression checks. */
public final class Core {
    private Core() {}
    public static final long MAX_AUDIO = 128L * 1024 * 1024;
    public static final Set<String> EXTENSIONS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList("mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac")));
    public enum Mode {
        SEQUENTIAL("顺序播放"), LOOP("列表循环"), REPEAT("单曲循环"), SHUFFLE("随机播放");
        public final String label;
        Mode(String label) { this.label = label; }
    }
    public static String server(String input) {
        try {
            URI uri = new URI(input.trim());
            String host = uri.getHost(), scheme = uri.getScheme();
            boolean local = Arrays.asList("localhost", "127.0.0.1", "10.0.2.2").contains(host);
            if (host == null || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null ||
                    !(uri.getPath().isEmpty() || uri.getPath().equals("/")) ||
                    !("https".equals(scheme) || ("http".equals(scheme) && local))) throw new IllegalArgumentException();
            return new URI(scheme, null, host.toLowerCase(Locale.ROOT), uri.getPort(), null, null, null).toASCIIString();
        } catch (Exception error) { throw new IllegalArgumentException("请输入 HTTPS 服务器地址，本机开发可使用 http://10.0.2.2:8080"); }
    }
    public static String hash(byte[] data) {
        try { return hex(MessageDigest.getInstance("SHA-256").digest(data)); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    public static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) text.append(String.format(Locale.ROOT, "%02x", value & 255));
        return text.toString();
    }
    public static String songKey(String server, String remoteId) {
        return hash((server + "/" + UUID.fromString(remoteId).toString()).getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
    public static int nextIndex(int size, int index, Mode mode, boolean automatic, Random random) {
        if (size == 0) return -1;
        if (index < 0 || index >= size) return 0;
        if (automatic && mode == Mode.REPEAT) return index;
        if (mode == Mode.SHUFFLE && size > 1) {
            int candidate = random.nextInt(size - 1);
            return candidate >= index ? candidate + 1 : candidate;
        }
        if (index + 1 < size) return index + 1;
        return mode == Mode.LOOP || mode == Mode.SHUFFLE ? 0 : -1;
    }
    public static <T> T different(List<T> choices, T previous, Random random) {
        List<T> alternatives = new ArrayList<>(choices);
        alternatives.removeIf(item -> Objects.equals(item, previous));
        if (alternatives.isEmpty()) alternatives.addAll(choices);
        return alternatives.isEmpty() ? null : alternatives.get(random.nextInt(alternatives.size()));
    }
    public interface Progress { void changed(long bytes); }
    public static void cache(InputStream source, File destination, long expectedSize, String expectedHash, Progress progress) throws IOException {
        if (expectedSize <= 0 || expectedSize > MAX_AUDIO || !expectedHash.matches("[0-9a-f]{64}")) throw new IOException("歌曲信息无效");
        File parent = destination.getParentFile();
        if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("无法创建离线存储目录");
        File temporary = File.createTempFile("download-", ".part", parent);
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            long total = 0;
            try (FileOutputStream out = new FileOutputStream(temporary)) {
                byte[] buffer = new byte[32768];
                int read;
                while ((read = source.read(buffer)) != -1) {
                    if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                    total += read;
                    if (total > expectedSize || total > MAX_AUDIO) throw new IOException("下载文件大小不符");
                    digest.update(buffer, 0, read);
                    out.write(buffer, 0, read);
                    if (progress != null) progress.changed(total);
                }
                out.getFD().sync();
            }
            if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
            if (total != expectedSize || !hex(digest.digest()).equals(expectedHash)) throw new IOException("歌曲下载不完整，请重试");
            Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
        finally { if (temporary.exists()) temporary.delete(); }
    }
    public static String time(long millis) {
        long seconds = Math.max(0, millis) / 1000;
        return seconds >= 3600 ? String.format(Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60);
    }
}
