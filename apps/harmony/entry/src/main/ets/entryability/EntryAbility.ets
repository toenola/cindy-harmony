import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindowStage: window.WindowStage | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'CindyHarmony', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'CindyHarmony', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'CindyHarmony', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'CindyHarmony', '%{public}s', 'Ability onWindowStageCreate');
    this.mainWindowStage = windowStage;

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'CindyHarmony', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'CindyHarmony', 'Succeeded in loading the content.');
      void this.applyNavigationBarAppearance(windowStage);
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    this.mainWindowStage = null;
    hilog.info(DOMAIN, 'CindyHarmony', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'CindyHarmony', '%{public}s', 'Ability onForeground');
    if (this.mainWindowStage !== null) {
      void this.applyNavigationBarAppearance(this.mainWindowStage);
    }
    // 回前台：立即重连（后台期间 WS 可能已断），并触发重连后的订阅恢复。
    AppServices.instance.onAppForeground();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'CindyHarmony', '%{public}s', 'Ability onBackground');
  }

  private async applyNavigationBarAppearance(windowStage: window.WindowStage): Promise<void> {
    try {
      const resourceManager = this.context.resourceManager;
      const navigationBarColor = this.colorToHex(resourceManager.getColorByNameSync('bg_page'));
      const navigationBarContentColor = this.colorToHex(
        resourceManager.getColorByNameSync('text_primary'));
      const isDarkMode = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      const mainWindow = await windowStage.getMainWindow();
      await mainWindow.setWindowSystemBarProperties({
        navigationBarColor,
        navigationBarContentColor,
        isNavigationBarLightIcon: isDarkMode,
      });
    } catch (err) {
      hilog.error(DOMAIN, 'CindyHarmony',
        'Failed to apply navigation bar appearance. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private colorToHex(color: number): string {
    // Resource colors may arrive as signed ARGB32 values; normalize before formatting.
    const normalized = color >>> 0;
    let hex = normalized.toString(16);
    while (hex.length < 6) {
      hex = `0${hex}`;
    }
    return `#${hex.substring(hex.length - 6)}`;
  }
}