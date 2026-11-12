package studio.sonora.android;

import android.app.Application;
import android.content.Context;

public final class SonoraApp extends Application {
    private Repository repository;
    @Override public void onCreate() { super.onCreate(); repository = new Repository(this); }
    public static Repository repository(Context context) { return ((SonoraApp) context.getApplicationContext()).repository; }
}
