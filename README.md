# CODM Control — broad Android compatibility build

This is a source project for a native Android companion app plus a KernelSU/Magisk module. It is designed for **Android 6.0 (API 23) and newer**, across ARM/ARM64/x86/x86_64 where the device's Android runtime and WebView are compatible. This is a best-effort compatibility target, **not a guarantee that every phone, ROM, root manager, or kernel will support every feature**.

## Build outputs

GitHub Actions builds:
- `CODM_Control.apk` — companion app APK
- `CODM_Ultra_Stretch_v1_15_Universal_App.zip` — module ZIP containing the APK as a systemless system app

## Build

1. Upload the contents of this directory to a GitHub repository.
2. Open **Actions → Build CODM Control APK and Universal Module ZIP → Run workflow**.
3. Download the artifact named `CODM-Control-Universal-App-and-Module`.
4. Back up your current module/configuration. Disable/remove older conflicting versions, install the new module ZIP in KernelSU/Magisk, then reboot.

## Compatibility behavior

- The app is Java/WebView-based and does not bundle native CPU-architecture-specific libraries.
- The app opens the local module dashboard at `http://127.0.0.1:8088/`. The module must be enabled and its local web server must successfully bind that port. If the module config uses another `WEBUI_PORT`, update `DASHBOARD` in `MainActivity.java` and rebuild.
- Privileged work is performed by the root module service, not by trusting UI JavaScript to write kernel nodes directly. The app does not need to request interactive `su` access for the existing module-service design.
- The APK is bundled at `module/system/app/CODMControl/CODMControl.apk` for systemless mounting. Some ROMs/root managers may not expose mounted system apps until reboot, may enforce signature/partition rules, or may reject this method. On those devices install `CODM_Control.apk` manually as a normal app instead.
- CPU/GPU frequencies, governors, thermal controls, stretch/resolution changes, overlay permissions, and game detection vary by device. Missing/readonly controls must be treated as unsupported. Never assume a displayed profile means hardware accepted it.
- Android 6+ is the stated minimum; older Android versions are not supported. Newer Android versions and vendor ROMs still require on-device validation.

## Safety / validation

- Test first with CPU/GPU controls disabled, then enable a conservative profile only if the device exposes supported controls.
- Confirm the module restores original values after CODM loses foreground or the service stops. If it does not, disable the module and reboot.
- Do not claim universal real-time 1 ms response: Android scheduling, WebView rendering, shell polling, and kernel interfaces cannot guarantee that.
- No APK was precompiled in this source archive. GitHub Actions builds it with Android Gradle Plugin and Java 17; installation and behavior must be tested on real devices.
