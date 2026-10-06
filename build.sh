#!/usr/bin/env bash
#
# Builds Force Dark Mode with the Android SDK build-tools only - no Gradle.
#
#   ANDROID_HOME=/path/to/sdk ./build.sh     # XPOSED_JAR defaults to api-82.jar next to this file
#
# Produces force-dark-mode-debug.apk and force-dark-mode-release.apk.
#
# The debug APK is signed with a generated debug.keystore and marked android:debuggable.
# The release APK is signed with a release keystore when one is supplied, otherwise it falls
# back to the debug key so a fresh checkout still produces something installable:
#
#   KEYSTORE_PATH=/path/to/release.keystore KEYSTORE_PASSWORD=... KEY_ALIAS=... KEY_PASSWORD=...
#
# KEYSTORE_BASE64 is accepted instead of KEYSTORE_PATH and is decoded inline, which is how the
# GitHub Actions workflow feeds the signing key in.
#
# XPOSED_JAR is only needed to compile; nothing from it is packaged.

set -euo pipefail

: "${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"

BT_VER="${BT_VER:-36.0.0}"
API="${API:-36}"
APP_NAME="${APP_NAME:-force-dark-mode}"
BUILD_TOOLS="$ANDROID_HOME/build-tools/$BT_VER"
ANDROID_JAR="$ANDROID_HOME/platforms/android-$API/android.jar"
HERE="$(cd "$(dirname "$0")" && pwd)"
XPOSED_JAR="${XPOSED_JAR:-$HERE/api-82.jar}"

cd "$HERE"

# build-tools ship d8/apksigner as .bat on Windows and as extensionless scripts elsewhere.
tool_path() {
    local name="$1"
    if [ -f "$BUILD_TOOLS/$name.bat" ]; then
        echo "$BUILD_TOOLS/$name.bat"
    elif [ -x "$BUILD_TOOLS/$name.exe" ]; then
        echo "$BUILD_TOOLS/$name.exe"
    elif [ -x "$BUILD_TOOLS/$name" ]; then
        echo "$BUILD_TOOLS/$name"
    else
        echo "missing build-tool: $name in $BUILD_TOOLS" >&2
        return 1
    fi
}

AAPT="$(tool_path aapt)"
D8="$(tool_path d8)"
ZIPALIGN="$(tool_path zipalign)"
APKSIGNER="$(tool_path apksigner)"

[ -f "$ANDROID_JAR" ] || { echo "missing $ANDROID_JAR" >&2; exit 1; }
[ -f "$XPOSED_JAR" ] || { echo "missing $XPOSED_JAR (set XPOSED_JAR)" >&2; exit 1; }

# javac wants ';' as the classpath separator on Windows and ':' elsewhere.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) CP_SEP=';' ;;
    *) CP_SEP=':' ;;
esac

# A base64 keystore from CI takes the place of a key file.
if [ -z "${KEYSTORE_PATH:-}" ] && [ -n "${KEYSTORE_BASE64:-}" ]; then
    echo "$KEYSTORE_BASE64" | base64 -d > release.keystore
    KEYSTORE_PATH="$HERE/release.keystore"
fi

ensure_debug_keystore() {
    if [ ! -f debug.keystore ]; then
        echo "== generating debug.keystore =="
        keytool -genkeypair -keystore debug.keystore -storepass android -keypass android \
            -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
            -dname "CN=Android Debug,O=Android,C=US" >/dev/null
    fi
}

build_variant() {
    local variant="$1"
    local out="build/$variant"
    rm -rf "$out"
    mkdir -p "$out/classes"

    # debug carries android:debuggable, release does not.
    if [ "$variant" = "debug" ]; then
        sed 's|<application |<application android:debuggable="true" |' \
            AndroidManifest.xml > "$out/AndroidManifest.xml"
    else
        cp AndroidManifest.xml "$out/AndroidManifest.xml"
    fi

    echo "== $variant: javac =="
    javac -source 1.8 -target 1.8 -cp "$ANDROID_JAR$CP_SEP$XPOSED_JAR" -d "$out/classes" \
        $(find src -name '*.java') 2>&1 | grep -v -E "bootstrap class path|obsolete|Xlint|^[0-9]+ warning|^Note:" || true

    echo "== $variant: d8 =="
    "$D8" --lib "$ANDROID_JAR" --min-api 24 --output "$out" \
        $(find "$out/classes" -name '*.class')

    echo "== $variant: aapt =="
    "$AAPT" package -f -M "$out/AndroidManifest.xml" -I "$ANDROID_JAR" \
        -S res -A assets -F "$out/module.unsigned.apk"

    PY="$(command -v python3 || command -v python)"
    "$PY" - "$out" <<'PY'
import shutil, sys, zipfile
out = sys.argv[1]
shutil.copyfile(f"{out}/module.unsigned.apk", f"{out}/module.withdex.apk")
with zipfile.ZipFile(f"{out}/module.withdex.apk", "a", zipfile.ZIP_STORED) as z:
    z.write(f"{out}/classes.dex", "classes.dex")
PY

    "$ZIPALIGN" -f -p 4 "$out/module.withdex.apk" "$out/module.aligned.apk"

    echo "== $variant: sign =="
    if [ "$variant" = "release" ] && [ -n "${KEYSTORE_PATH:-}" ] && [ -f "${KEYSTORE_PATH:-}" ]; then
        "$APKSIGNER" sign --ks "$KEYSTORE_PATH" \
            --ks-pass "pass:${KEYSTORE_PASSWORD:?set KEYSTORE_PASSWORD}" \
            --key-pass "pass:${KEY_PASSWORD:?set KEY_PASSWORD}" \
            --ks-key-alias "${KEY_ALIAS:?set KEY_ALIAS}" \
            --out "$APP_NAME-$variant.apk" "$out/module.aligned.apk"
    else
        [ "$variant" = "release" ] && \
            echo "   no release keystore supplied - signing the release APK with the debug key"
        ensure_debug_keystore
        "$APKSIGNER" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
            --ks-key-alias androiddebugkey \
            --out "$APP_NAME-$variant.apk" "$out/module.aligned.apk"
    fi

    ls -l "$APP_NAME-$variant.apk"
}

build_variant debug
build_variant release

echo
echo "== done =="
ls -l "$APP_NAME-debug.apk" "$APP_NAME-release.apk"
