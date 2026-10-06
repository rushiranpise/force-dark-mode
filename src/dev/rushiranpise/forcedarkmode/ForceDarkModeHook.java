package dev.rushiranpise.forcedarkmode;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Forces dark rendering in the apps this module is scoped to.
 *
 * There is no system API for "render this app dark no matter what it supports", so the module
 * takes over the two decisions that gate force dark. Both are made inside the target app's own
 * process, which is why the module only affects the apps picked in its LSPosed scope.
 *
 * 1. ViewRootImpl.determineForceDarkType() decides per window, and on One UI 8.5 it looks like:
 *
 *        int determineForceDarkType() {
 *            if (getNightMode() == UI_MODE_NIGHT_YES) {                      // 32
 *                boolean prop    = SystemProperties.getBoolean("debug.hwui.force_dark", false);
 *                boolean allowed = theme.getBoolean(forceDarkAllowed, true); // 0x117
 *                if (!allowed) return ...;
 *                if (!theme.getBoolean(forceDark, prop)) return ...;         // 0x116
 *                return View.FORCE_DARK_ON;
 *            }
 *            ...
 *        }
 *
 *    The developer option only ever sets that property, and it is consulted only when the app is
 *    already in night mode, with the app's theme still able to veto it. Returning FORCE_DARK_ON
 *    here removes both conditions.
 *
 * 2. A window wide decision is not enough: HWUI still skips any view whose render node disallows
 *    force dark, which an app sets with View.setForceDarkAllowed(false). That argument is coerced
 *    back to true, and isForceDarkAllowed() reports true as well, so a single view cannot refuse.
 *
 * The module does not change colours, theme resources or night mode; it only turns on the
 * renderer's force dark path.
 */
public class ForceDarkModeHook implements IXposedHookLoadPackage {

    private static final String TAG = "ForceDarkMode";

    /** Scoping the module to itself would be pointless. */
    private static final String OWN_PACKAGE = "dev.rushiranpise.forcedarkmode";

    private static final String VIEW_ROOT_IMPL_CLASS = "android.view.ViewRootImpl";
    private static final String DETERMINE_FORCE_DARK_METHOD = "determineForceDarkType";

    private static final String VIEW_CLASS = "android.view.View";
    private static final String SET_FORCE_DARK_ALLOWED_METHOD = "setForceDarkAllowed";
    private static final String IS_FORCE_DARK_ALLOWED_METHOD = "isForceDarkAllowed";

    /** android.view.View.FORCE_DARK_ON - ViewRootImpl returns exactly this from its night branch. */
    private static final int FORCE_DARK_ON = 1;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        if (OWN_PACKAGE.equals(lpparam.packageName)) {
            return;
        }

        hookWindowLevel(lpparam);
        hookPerView(lpparam);
    }

    private void hookWindowLevel(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            XposedHelpers.findAndHookMethod(
                VIEW_ROOT_IMPL_CLASS,
                lpparam.classLoader,
                DETERMINE_FORCE_DARK_METHOD,
                new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                        param.setResult(FORCE_DARK_ON);
                    }
                }
            );
            XposedBridge.log(TAG + ": window level force dark in " + lpparam.packageName);
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": window level force dark failed in " + lpparam.packageName + " - " + t);
        }
    }

    private void hookPerView(XC_LoadPackage.LoadPackageParam lpparam) {
        Class<?> view = XposedHelpers.findClassIfExists(VIEW_CLASS, lpparam.classLoader);
        if (view == null) {
            XposedBridge.log(TAG + ": " + VIEW_CLASS + " missing in " + lpparam.packageName);
            return;
        }

        try {
            // Matched by name only, so a different parameter list cannot break the hooks.
            XposedBridge.hookAllMethods(view, SET_FORCE_DARK_ALLOWED_METHOD, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    if (param.args != null && param.args.length == 1 && param.args[0] instanceof Boolean) {
                        param.args[0] = Boolean.TRUE;
                    }
                }
            });
            XposedBridge.hookAllMethods(view, IS_FORCE_DARK_ALLOWED_METHOD, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    param.setResult(Boolean.TRUE);
                }
            });
            XposedBridge.log(TAG + ": per view force dark in " + lpparam.packageName);
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": per view force dark failed in " + lpparam.packageName + " - " + t);
        }
    }
}
