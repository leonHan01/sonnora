package studio.sonora.android;

import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Tokens never enter catalog files, URLs, notifications, or the APK. */
public final class Credentials {
    private static final String ALIAS = "sonora.server.credentials.v1";
    private final SharedPreferences prefs;
    public Credentials(Context context) { prefs = context.getSharedPreferences("connection", Context.MODE_PRIVATE); }
    public String server() { return prefs.getString("server", "https://121.40.254.112"); }
    public boolean enabled() { return prefs.getBoolean("enabled", true); }
    private String slot(String server) { return "token_" + Core.hash(server.getBytes(StandardCharsets.UTF_8)); }
    private SecretKey key() throws GeneralSecurityException {
        try {
            KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
            if (store.containsAlias(ALIAS)) return (SecretKey) store.getKey(ALIAS, null);
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build());
            return generator.generateKey();
        } catch (java.io.IOException error) { throw new GeneralSecurityException(error); }
    }
    public String token(String server) throws GeneralSecurityException {
        String saved = prefs.getString(slot(server), "");
        if (saved.isEmpty()) return "";
        try {
            String[] parts = saved.split(":");
            if (parts.length != 2) throw new GeneralSecurityException();
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
            cipher.updateAAD(server.getBytes(StandardCharsets.UTF_8));
            return new String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException error) { throw new GeneralSecurityException(error); }
    }
    public void save(String input, boolean enabled, String inputToken, boolean clear) throws GeneralSecurityException {
        String server = Core.server(input), token = inputToken.trim();
        if (token.length() > 1000 || token.contains("\n") || token.contains("\r")) throw new IllegalArgumentException("访问令牌格式无效");
        SharedPreferences.Editor editor = prefs.edit();
        if (clear) editor.remove(slot(server));
        else if (!token.isEmpty()) {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(server.getBytes(StandardCharsets.UTF_8));
            String value = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":" + Base64.encodeToString(cipher.doFinal(token.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
            editor.putString(slot(server), value);
        }
        if (!editor.putString("server", server).putBoolean("enabled", enabled).commit()) throw new GeneralSecurityException("无法保存连接设置");
    }
}
