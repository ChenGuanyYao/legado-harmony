import { Context } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderFontHelper, ReaderFontItem } from './ReaderFontHelper';
import { ReaderSettings, ReaderSettingsStore } from './ReaderSettingsStore';
import { ReaderSystemFontHelper } from './ReaderSystemFontHelper';
import { ThemeRuntime } from '../theme/ThemeRuntime';

export class ReaderFontBootstrap {
  // The user's global font wins over the theme font; the theme font only applies while "跟随主题" is selected.
  static applicationFontFamily(): string {
    const activeFamily = AppStorage.get<string>('readerActiveFontFamily') || '';
    if (activeFamily && AppStorage.get<boolean>('readerFontRegistered')) {
      return activeFamily;
    }
    return ThemeRuntime.fontFamily() || AppStorage.get<string>('readerSystemFontFamily') || '';
  }

  static applyApplicationFont(context: Context, source: string): void {
    try {
      context.getApplicationContext().setFont(ReaderFontBootstrap.applicationFontFamily());
    } catch (err) {
      hilog.warn(0x0000, 'testTag', 'Apply application font failed source=%{public}s err=%{public}s',
        source, JSON.stringify(err));
    }
  }

  static async registerFromSettings(context: Context, uiContext: UIContext | null, source: string): Promise<boolean> {
    try {
      const settings = await ReaderSettingsStore.load(context);
      return ReaderFontBootstrap.registerSettings(context, uiContext, settings, source);
    } catch (err) {
      hilog.warn(0x0000, 'testTag', 'Reader font bootstrap load failed source=%{public}s err=%{public}s',
        source, JSON.stringify(err));
      return false;
    }
  }

  private static registerSettings(
    context: Context,
    uiContext: UIContext | null,
    settings: ReaderSettings,
    source: string
  ): boolean {
    if (!settings.fontFilePath) {
      const systemFontFamily = ReaderSystemFontHelper.applyToStorage(uiContext);
      AppStorage.setOrCreate('readerActiveFontFamily', '');
      AppStorage.setOrCreate('readerFontRegistered', false);
      ReaderFontBootstrap.applyApplicationFont(context, source);
      if (settings.systemFontFamily !== systemFontFamily) {
        ReaderSettingsStore.saveFontSettings(
          context,
          '',
          '',
          settings.fontSourceName,
          settings.fontMode,
          systemFontFamily,
          settings.customFontsRaw
        ).catch((err: Error) => {
          hilog.warn(0x0000, 'testTag',
            'Reader font bootstrap save system font failed source=%{public}s err=%{public}s',
            source, JSON.stringify(err));
        });
      }
      return false;
    }

    const fontItem = new ReaderFontItem();
    fontItem.familyName = settings.fontFamily || ReaderFontHelper.normalizeFontFamily(settings.fontFilePath);
    fontItem.filePath = settings.fontFilePath;
    fontItem.sourceName = ReaderFontHelper.resolveDisplayName(settings.fontSourceName, settings.fontFilePath);

    const result = ReaderFontHelper.registerFont(uiContext, fontItem);
    if (!result.registered) {
      AppStorage.setOrCreate('readerActiveFontFamily', '');
      AppStorage.setOrCreate('readerFontRegistered', false);
      ReaderFontBootstrap.applyApplicationFont(context, source);
      hilog.warn(0x0000, 'testTag',
        'Reader font bootstrap failed source=%{public}s path=%{public}s family=%{public}s ark=%{public}s legacy=%{public}s graphics=%{public}s errors=%{public}s',
        source, result.filePath || settings.fontFilePath, result.familyName, String(result.arkUiRegistered),
        String(result.legacyRegistered), String(result.graphicsTextRegistered), result.errorSummary);
      return false;
    }

    AppStorage.setOrCreate('readerActiveFontFamily', result.familyName);
    AppStorage.setOrCreate('readerFontRegistered', true);
    if (result.filePath !== settings.fontFilePath) {
      AppStorage.setOrCreate('readerFontFilePath', result.filePath);
      ReaderSettingsStore.saveFontSettings(
        context,
        ReaderFontHelper.normalizeFontFamily(result.filePath),
        result.filePath,
        settings.fontSourceName,
        settings.fontMode,
        settings.systemFontFamily,
        settings.customFontsRaw
      ).catch((err: Error) => {
        hilog.warn(0x0000, 'testTag',
          'Reader font bootstrap save migrated path failed source=%{public}s err=%{public}s',
          source, JSON.stringify(err));
      });
    }

    try {
      context.getApplicationContext().setFont(result.familyName);
    } catch (err) {
      hilog.warn(0x0000, 'testTag', 'Reader font bootstrap setFont failed source=%{public}s err=%{public}s',
        source, JSON.stringify(err));
    }

    hilog.info(0x0000, 'testTag',
      'Reader font bootstrap success source=%{public}s family=%{public}s path=%{public}s arkSrc=%{public}s graphicsSrc=%{public}s',
      source, result.familyName, result.filePath, result.arkUiSource, result.graphicsTextSource);
    return true;
  }
}
