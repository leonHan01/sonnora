package studio.sonora.android;

import android.content.*;
import android.content.res.ColorStateList;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.*;
import android.util.LruCache;
import android.view.*;
import android.widget.*;
import java.io.File;
import java.lang.ref.WeakReference;
import java.util.concurrent.*;

final class Ui {
    static final int BG = 0xff0e1115, PANEL = 0xff181d23, RAISED = 0xff222a30, ACCENT = 0xffc5f06e, TEXT = 0xfff0f2ed, MUTED = 0xff8b969a, LINE = 0xff293137;
    static int dp(Context context, float value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }
    static GradientDrawable round(Context context, int color, int radius) { GradientDrawable value = new GradientDrawable(); value.setColor(color); value.setCornerRadius(dp(context, radius)); return value; }
    static TextView text(Context context, String text, float size, int color) {
        TextView view = new TextView(context); view.setText(text); view.setTextSize(size); view.setTextColor(color); view.setFontFeatureSettings("kern"); return view;
    }
    static LinearLayout column(Context context) { LinearLayout layout = new LinearLayout(context); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    static LinearLayout row(Context context) { LinearLayout layout = new LinearLayout(context); layout.setGravity(Gravity.CENTER_VERTICAL); return layout; }
    static void padding(View view, int horizontal, int vertical) { view.setPadding(dp(view.getContext(), horizontal), dp(view.getContext(), vertical), dp(view.getContext(), horizontal), dp(view.getContext(), vertical)); }
    static Button button(Context context, String text, boolean primary, View.OnClickListener action) {
        Button button = new Button(context); button.setText(text); button.setTextSize(14); button.setAllCaps(false); button.setMinHeight(dp(context, 48)); button.setMinimumHeight(dp(context, 48));
        button.setTextColor(primary ? BG : TEXT); button.setTypeface(null, Typeface.BOLD); padding(button, 18, 8);
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x338b969a), round(context, primary ? ACCENT : RAISED, 16), null));
        button.setOnClickListener(action); return button;
    }
    static ImageButton icon(Context context, int resource, String label, View.OnClickListener action) {
        ImageButton view = new ImageButton(context); view.setImageResource(resource); view.setImageTintList(ColorStateList.valueOf(MUTED));
        view.setBackground(new RippleDrawable(ColorStateList.valueOf(0x336b8066), round(context, 0x00000000, 20), null));
        padding(view, 11, 11); view.setContentDescription(label); view.setOnClickListener(action); view.setFocusable(false);
        view.setLayoutParams(new LinearLayout.LayoutParams(dp(context, 48), dp(context, 48))); return view;
    }
    static EditText input(Context context, String hint) {
        EditText edit = new EditText(context); edit.setTextSize(14); edit.setTextColor(TEXT); edit.setHintTextColor(MUTED); edit.setHint(hint);
        edit.setSingleLine(true); padding(edit, 15, 13); edit.setBackground(round(context, PANEL, 14)); edit.setSelectAllOnFocus(false); return edit;
    }
    static LinearLayout.LayoutParams weight() { return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1); }
    static View space(Context context, int height) { View view = new View(context); view.setLayoutParams(new LinearLayout.LayoutParams(1, dp(context, height))); return view; }
    static final ExecutorService images = Executors.newFixedThreadPool(2);
    static final Handler main = new Handler(Looper.getMainLooper());
    static final LruCache<String, Bitmap> covers = new LruCache<String, Bitmap>(8 * 1024 * 1024) {
        @Override protected int sizeOf(String key, Bitmap value) { return value.getAllocationByteCount(); }
    };
    static final class Art extends ImageView {
        private String bound = "";
        private Future<?> pending;
        public Art(Context context) { this(context, 48); }
        Art(Context context, int size) {
            super(context); setLayoutParams(new LinearLayout.LayoutParams(dp(context, size), dp(context, size)));
            setBackground(round(context, RAISED, size > 100 ? 22 : 10)); setClipToOutline(true);
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO); placeholder();
        }
        private void placeholder() { setScaleType(ScaleType.CENTER_INSIDE); setPadding(0, 0, 0, 0); setImageResource(R.drawable.ic_notification); setImageTintList(ColorStateList.valueOf(0xff52614c)); }
        void bind(Repository repo, Song song, int pixels) {
            File file = song == null ? null : repo.artwork(song);
            String key = file == null ? "empty" : file.getAbsolutePath() + ":" + file.lastModified() + ":" + pixels;
            if (key.equals(bound)) return;
            bound = key; if (pending != null) pending.cancel(true); placeholder();
            if (file == null || !file.isFile()) return;
            Bitmap cached = covers.get(key); if (cached != null) { show(cached); return; }
            WeakReference<Art> target = new WeakReference<>(this);
            pending = images.submit(() -> {
                BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true; BitmapFactory.decodeFile(file.getAbsolutePath(), options);
                options.inSampleSize = 1; while (Math.max(options.outWidth, options.outHeight) / options.inSampleSize > pixels * 2) options.inSampleSize *= 2;
                options.inJustDecodeBounds = false; Bitmap value = BitmapFactory.decodeFile(file.getAbsolutePath(), options);
                if (value == null || Thread.currentThread().isInterrupted()) return;
                covers.put(key, value);
                main.post(() -> { Art image = target.get(); if (image != null && image.bound.equals(key)) image.show(value); });
            });
        }
        private void show(Bitmap bitmap) { setImageTintList(null); setScaleType(ScaleType.CENTER_CROP); setImageBitmap(bitmap); }
        @Override protected void onDetachedFromWindow() { if (pending != null) pending.cancel(true); bound = ""; super.onDetachedFromWindow(); }
    }
}
