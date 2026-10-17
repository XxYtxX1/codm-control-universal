package com.codm.ultrastretch;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.view.View;
import android.view.Gravity;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebSettings;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private static final String DASHBOARD = "http://127.0.0.1:8088/";
    private WebView webView;
    private LinearLayout fallback;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(Color.rgb(11,13,18));
        getWindow().setNavigationBarColor(Color.rgb(11,13,18));
        buildViews();
        loadDashboard();
    }

    private void buildViews() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(11,13,18));
        webView = new WebView(this);
        webView.setBackgroundColor(Color.rgb(11,13,18));
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(false);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);
        settings.setLoadsImagesAutomatically(true);
        settings.setBlockNetworkImage(false);
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        webView.setWebChromeClient(new WebChromeClient());
        webView.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String host = request.getUrl().getHost();
                return host == null || !(host.equals("127.0.0.1") || host.equals("localhost"));
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request != null && request.isForMainFrame()) showFallback();
            }
            @SuppressWarnings("deprecation")
            @Override public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                if (android.os.Build.VERSION.SDK_INT < 23) showFallback();
            }
        });
        root.addView(webView, new LinearLayout.LayoutParams(-1, -1));
        fallback = new LinearLayout(this);
        fallback.setOrientation(LinearLayout.VERTICAL);
        fallback.setGravity(Gravity.CENTER);
        fallback.setPadding(28, 28, 28, 28);
        fallback.setBackgroundColor(Color.rgb(11,13,18));
        TextView title = new TextView(this);
        title.setText("CODM CONTROL"); title.setTextColor(Color.rgb(255,176,32)); title.setTextSize(23); title.setGravity(Gravity.CENTER);
        TextView info = new TextView(this);
        info.setText("The module WebUI is not responding yet. Make sure CODM Ultra Stretch is enabled in KernelSU/Magisk, then retry. The app uses the module's local dashboard; privileged operations are performed by the module service.");
        info.setTextColor(Color.rgb(220,225,235)); info.setTextSize(15); info.setGravity(Gravity.CENTER); info.setPadding(0,18,0,18);
        Button retry = new Button(this); retry.setText("RETRY CONNECTION"); retry.setOnClickListener(v -> loadDashboard());
        fallback.addView(title, new LinearLayout.LayoutParams(-1, -2));
        fallback.addView(info, new LinearLayout.LayoutParams(-1, -2));
        fallback.addView(retry, new LinearLayout.LayoutParams(-1, -2));
        root.addView(fallback, new LinearLayout.LayoutParams(-1, -1));
        setContentView(root);
        fallback.setVisibility(View.GONE);
    }

    private void loadDashboard() {
        fallback.setVisibility(View.GONE);
        webView.setVisibility(View.VISIBLE);
        webView.loadUrl(DASHBOARD);
    }

    private void showFallback() {
        webView.setVisibility(View.GONE);
        fallback.setVisibility(View.VISIBLE);
    }

    @Override public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }
    @Override protected void onDestroy() {
        if (webView != null) { webView.stopLoading(); webView.destroy(); webView = null; }
        super.onDestroy();
    }
}
