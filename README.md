# Force Dark Mode

An LSPosed module that forces dark rendering in the apps you choose, regardless of whether those
apps support a dark theme.

Package: `dev.rushiranpise.forcedarkmode` · Min SDK 24 · Built against android-36

## What it does

There is no framework API for "render this app dark no matter what it supports", so the module takes
over the two decisions that gate force dark. Both live inside the target app's own process, which is
why it only affects the apps you scope it to.

**1. The per-window decision.** `ViewRootImpl.determineForceDarkType()` picks the force dark type for
each window. On One UI 8.5 that method reads:

```java
int determineForceDarkType() {
    if (getNightMode() == UI_MODE_NIGHT_YES) {                      // 32
        boolean prop    = SystemProperties.getBoolean("debug.hwui.force_dark", false);
        boolean allowed = theme.getBoolean(forceDarkAllowed, true); // 0x117
        if (!allowed) return ...;
        if (!theme.getBoolean(forceDark, prop)) return ...;         // 0x116
        return View.FORCE_DARK_ON;
    }
    ...
}
```

The module returns `FORCE_DARK_ON` from it. That lifts both conditions at once: the
`debug.hwui.force_dark` property is only consulted when the app is already in night mode, and the
app's own theme can still veto it.

**2. The per-view decision.** A window-wide answer is not enough on its own, because HWUI skips any
view whose render node disallows force dark - which an app sets with `View.setForceDarkAllowed(false)`.
The module coerces that argument back to `true` and reports `true` from `isForceDarkAllowed()`, so a
single view cannot refuse either.

Every hook is matched by name only, so a different parameter list on another ROM cannot break the
module - it logs the failure and carries on.

## What it does not do

- It does not change colours, themes, night mode or any system setting. It only turns on the
  renderer's force dark path.
- It does not make apps follow the light/dark switch. It forces dark rendering.
- It only reaches the normal View rendering pipeline. Apps drawn with WebView, Jetpack Compose,
  Flutter or a game engine usually stay light, because those do not draw through HWUI's force dark
  path.

## Requirements

- LSPosed (Zygisk) with root
- A ROM that has `ViewRootImpl.determineForceDarkType()` and `View.setForceDarkAllowed()` -
  Android 10 and later on both AOSP and One UI

## Install and use

1. Install the APK.
2. In **LSPosed → Modules → Force Dark Mode**, enable the module.
3. Set its **scope to the apps you want darkened**. That scope list is the app picker - ticking an
   app is what makes it dark. The module ships no default scope on purpose, since there is no
   sensible default set of apps.

   Nothing else belongs in the scope. `View` and `ViewRootImpl` are boot classpath classes that
   exist in every app process, and force dark is decided in that process while it draws, so
   **System Framework** and **com.android.settings** are not involved. Adding System Framework would
   only load the module into `system_server`, where no app window is drawn, and add an invasive
   scope for no effect. Do not tick it.

4. Force stop and reopen each app. The hooks are installed when the process starts, so an app that
   is already running is untouched until it restarts.

To confirm it attached, look for this in the log:

```
adb logcat -s LSPosedFramework | grep ForceDarkMode
```

```
ForceDarkMode: window level force dark in <package>
ForceDarkMode: per view force dark in <package>
```

## Trade-offs

- Per-view opt-outs are overridden, so an app can no longer keep one view light on purpose. An image
  viewer, a map or a signature pad that the developer deliberately left light will be darkened too.
- Force dark is a renderer-level colour transform, so results on complex layouts can look muddy
  rather than designed.

## Repository layout

```
AndroidManifest.xml                                  module metadata (no xposedscope on purpose)
assets/xposed_init                                   entry point -> dev.rushiranpise.forcedarkmode.ForceDarkModeHook
res/values/strings.xml                               app label
src/dev/rushiranpise/forcedarkmode/
    ForceDarkModeHook.java                           both hooks, documented against the framework source
build.sh                                             builds the debug and release APKs, no Gradle
.github/workflows/release.yml                        CI: builds both APKs, publishes them on a tag
```

## Build

Needs a JDK, an Android SDK and the Xposed API jar (only to compile against - nothing from it is
packaged).

```bash
ANDROID_HOME=/path/to/sdk \
XPOSED_JAR=/path/to/api-82.jar \
./build.sh
```

Defaults to build-tools `36.0.0` and platform `android-36`; override with `BT_VER` and `API`.
`XPOSED_JAR` defaults to `api-82.jar` next to `build.sh`. The API jar is
`de.robv.android.xposed:api:82`.

Outputs:

| APK | Signed with | Notes |
| --- | --- | --- |
| `force-dark-mode-debug.apk` | generated `debug.keystore` | marked `android:debuggable="true"` |
| `force-dark-mode-release.apk` | your release keystore, else the debug key | no debug flag |

Release signing:

```bash
KEYSTORE_PATH=release.keystore \
KEYSTORE_PASSWORD=... KEY_ALIAS=... KEY_PASSWORD=... \
ANDROID_HOME=/path/to/sdk ./build.sh
```

`KEYSTORE_BASE64` works instead of `KEYSTORE_PATH` and is decoded inline, which is how CI supplies
the key.

## CI and releases

`.github/workflows/release.yml` runs on pushes to `main`/`master`, on pull requests, on `v*` tags and
on manual dispatch. It installs build-tools and the platform, downloads the Xposed API jar, then
builds both APKs and uploads them as artifacts.

On a `v*` tag it also publishes a GitHub release with both APKs attached. Signing comes from these
repository secrets, and the workflow still succeeds without them (the release APK is then debug
signed):

| Secret | Purpose |
| --- | --- |
| `KEYSTORE_BASE64` | base64 of the release keystore |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | key alias inside the keystore |
| `KEY_PASSWORD` | key password |

To cut a release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```
