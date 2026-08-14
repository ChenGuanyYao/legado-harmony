import { window } from '@kit.ArkUI';
import { ThemeRuntime } from '../theme/ThemeRuntime';

let safeAreaListenerRegistered = false;

export function syncSystemBars(context: Context, darkMode: boolean, backgroundColor?: string): void {
  const bg = backgroundColor || ThemeRuntime.pageColor(darkMode);
  window.getLastWindow(context).then((mainWindow: window.Window) => {
    mainWindow.setWindowBackgroundColor(bg);
    mainWindow.setWindowLayoutFullScreen(true);
    mainWindow.setWindowSystemBarEnable(['navigation', 'status']);
    syncSystemSafeAreas(mainWindow);
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      isStatusBarLightIcon: darkMode,
      statusBarContentColor: ThemeRuntime.primaryTextColor(darkMode),
      navigationBarColor: '#00000000',
      isNavigationBarLightIcon: darkMode,
      navigationBarContentColor: ThemeRuntime.primaryTextColor(darkMode)
    });
  }).catch((err: Error) => {
    console.error('同步系统栏颜色失败:', err);
  });
}

export function syncSystemSafeAreas(mainWindow: window.Window): void {
  try {
    const systemArea = mainWindow.getWindowAvoidAreaIgnoringVisibility(window.AvoidAreaType.TYPE_SYSTEM);
    const navigationArea = mainWindow.getWindowAvoidAreaIgnoringVisibility(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    const gestureArea = mainWindow.getWindowAvoidAreaIgnoringVisibility(window.AvoidAreaType.TYPE_SYSTEM_GESTURE);
    const topHeight = px2vp(Math.max(0, systemArea.topRect.height));
    const bottomHeight = px2vp(Math.max(
      0,
      navigationArea.bottomRect.height,
      gestureArea.bottomRect.height
    ));
    // A zero top avoid area is valid in landscape, free-form windows and on devices whose
    // system bar is not attached to the top edge. Treating it as a failed query leaves a
    // permanent 32vp strip in full-screen readers.
    AppStorage.setOrCreate('statusBarHeight', topHeight);
    AppStorage.setOrCreate('navBarHeight', bottomHeight > 0 ? bottomHeight : 0);
    registerSafeAreaListener(mainWindow);
  } catch (err) {
    console.error('同步系统安全区失败:', err);
    AppStorage.setOrCreate('statusBarHeight', AppStorage.get<number>('statusBarHeight') ?? 0);
    AppStorage.setOrCreate('navBarHeight', AppStorage.get<number>('navBarHeight') ?? 0);
  }
}

function registerSafeAreaListener(mainWindow: window.Window): void {
  if (safeAreaListenerRegistered) {
    return;
  }
  try {
    mainWindow.on('avoidAreaChange', (_data: window.AvoidAreaOptions) => {
      syncSystemSafeAreas(mainWindow);
    });
    safeAreaListenerRegistered = true;
  } catch (err) {
    console.error('注册系统安全区监听失败:', err);
  }
}
