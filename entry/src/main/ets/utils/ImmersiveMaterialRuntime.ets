import deviceInfo from '@ohos.deviceInfo';
import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { ThemeRuntime } from '../theme/ThemeRuntime';

/**
 * Applies the shared dropdown material to a Select. `menuSystemMaterial` only exists from API 26; calling the
 * attribute directly on an older system fails while the page is being built, so it is set through this modifier,
 * which leaves older systems on their platform default.
 */
export class SelectMenuMaterialModifier implements AttributeModifier<SelectAttribute> {
  applyNormalAttribute(instance: SelectAttribute): void {
    if (deviceInfo.sdkApiVersion < 26) return;
    instance.menuSystemMaterial(ImmersiveMaterialRuntime.selectMenuMaterial());
  }
}

/**
 * 彩色标签的沉浸光感胶囊：API 26+ 用透明的组件级沉浸材质（不压实色底），只叠一层很淡的标签文字色，
 * 交互光感也取这个颜色，按下时按标签自己的颜色泛光；边缘高光交给材质，不另画描边。
 * 旧系统画标签原本的浅底色。文字颜色由调用处照旧设置，按序号配色的规则不变。
 */
export class ImmersiveTagModifier implements AttributeModifier<CommonAttribute> {
  static readonly CAPSULE_RADIUS: number = 999;
  private fallbackColor: string;
  private lightColor: string;
  private darkMode: boolean;

  /**
   * @param fallbackColor 旧系统上的底色（标签原本的浅底色）
   * @param lightColor 标签文字色，用于材质淡染与光感颜色
   */
  constructor(fallbackColor: string, lightColor: string, darkMode: boolean) {
    this.fallbackColor = fallbackColor;
    this.lightColor = lightColor;
    this.darkMode = darkMode;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    const material = ImmersiveMaterialRuntime.tagMaterial(this.lightColor, this.darkMode);
    if (material !== undefined) {
      instance.backgroundColor(Color.Transparent);
      instance.systemMaterial(material);
      // 离屏合成会把材质压成平面，保持逐层绘制。
      instance.renderGroup(false);
    } else {
      instance.backgroundColor(this.fallbackColor);
    }
    // 胶囊形：圆角超过高度一半时按一半绘制。
    instance.borderRadius(ImmersiveTagModifier.CAPSULE_RADIUS);
  }
}

/** Centralizes HDS material probing and compatibility fallback. */
export class ImmersiveMaterialRuntime {
  static readonly KEY_LIGHT_LEVEL: string = 'immersiveLightLevel';
  /** 下拉弹出菜单的圆角与内边距；菜单项圆角取两者之差，与弹出层同心。 */
  static readonly POPUP_MENU_RADIUS: number = 18;
  static readonly POPUP_MENU_PADDING: number = 4;
  private static resolved: boolean = false;
  private static resolvedType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  private static hdsMaterialSupported: boolean | null = null;
  private static immersiveSupported: boolean | null = null;

  static supportsHds(): boolean {
    // ArkUI uiMaterial.ImmersiveMaterial is an API 26 feature. Keep this
    // capability separate from HDS tabs/material, which starts at API 23.
    if (deviceInfo.sdkApiVersion < 26) return false;
    if (ImmersiveMaterialRuntime.immersiveSupported !== null) {
      return ImmersiveMaterialRuntime.immersiveSupported;
    }
    try {
      ImmersiveMaterialRuntime.immersiveSupported = uiMaterial.isImmersiveMaterialSupported();
    } catch (error) {
      console.warn('读取沉浸光感设备能力失败，使用兼容界面:', error);
      ImmersiveMaterialRuntime.immersiveSupported = false;
    }
    return ImmersiveMaterialRuntime.immersiveSupported;
  }

  /** HDS tabs/floating bars and HDS system materials start at HarmonyOS 6/API 23. */
  static supportsHdsTabs(): boolean {
    return deviceInfo.sdkApiVersion >= 23;
  }

  /**
   * HDS system material (used by HdsTabs floating bars) is available from
   * HarmonyOS 6/API 23. This is intentionally separate from supportsHds(),
   * which checks the API 26 ArkUI uiMaterial namespace used by menus/buttons.
   */
  static supportsHdsMaterial(): boolean {
    if (!ImmersiveMaterialRuntime.supportsHdsTabs()) return false;
    if (ImmersiveMaterialRuntime.hdsMaterialSupported !== null) {
      return ImmersiveMaterialRuntime.hdsMaterialSupported;
    }
    try {
      const supportedTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      ImmersiveMaterialRuntime.hdsMaterialSupported = supportedTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0 ||
        supportedTypes.indexOf(hdsMaterial.MaterialType.ADAPTIVE) >= 0;
    } catch (error) {
      console.warn('读取 HDS 系统材质能力失败，使用兼容底栏:', error);
      ImmersiveMaterialRuntime.hdsMaterialSupported = false;
    }
    return ImmersiveMaterialRuntime.hdsMaterialSupported;
  }

  static materialType(): hdsMaterial.MaterialType {
    if (!ImmersiveMaterialRuntime.supportsHdsMaterial()) return hdsMaterial.MaterialType.NONE;
    if (ImmersiveMaterialRuntime.resolved) return ImmersiveMaterialRuntime.resolvedType;
    ImmersiveMaterialRuntime.resolved = true;
    try {
      const supportedTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      ImmersiveMaterialRuntime.resolvedType = supportedTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0 ?
        hdsMaterial.MaterialType.IMMERSIVE :
        supportedTypes.indexOf(hdsMaterial.MaterialType.ADAPTIVE) >= 0 ?
          hdsMaterial.MaterialType.ADAPTIVE : hdsMaterial.MaterialType.NONE;
    } catch (error) {
      console.warn('读取系统沉浸光感材质能力失败，使用兼容底栏:', error);
      ImmersiveMaterialRuntime.resolvedType = hdsMaterial.MaterialType.NONE;
    }
    return ImmersiveMaterialRuntime.resolvedType;
  }

  static materialLevel(): hdsMaterial.MaterialLevel {
    const configured = ImmersiveMaterialRuntime.configuredLightLevel();
    if (configured === 'high') return hdsMaterial.MaterialLevel.EXQUISITE;
    if (configured === 'balanced') return hdsMaterial.MaterialLevel.GENTLE;
    if (configured === 'weak') return hdsMaterial.MaterialLevel.SMOOTH;
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  /** Returns the persisted app-level light setting, defaulting to follow-system. */
  static configuredLightLevel(): string {
    return (AppStorage.get<string>(ImmersiveMaterialRuntime.KEY_LIGHT_LEVEL) || 'adaptive')
      .trim().toLowerCase();
  }

  /** Maps the app setting to the closest API 26 material style for component-level materials. */
  static materialStyle(): uiMaterial.ImmersiveStyle {
    const configured = ImmersiveMaterialRuntime.configuredLightLevel();
    if (configured === 'high') return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    if (configured === 'weak') return uiMaterial.ImmersiveStyle.THICK;
    return uiMaterial.ImmersiveStyle.REGULAR;
  }

  /**
   * Component-level immersive materials do not expose HDS MaterialLevel. Their
   * light-sense feedback is therefore mapped to the same app setting instead.
   * Undefined leaves the component-level light feedback unset, while null
   * disables it explicitly.
   */
  static lightEffect(forceAdaptive: boolean = false): uiMaterial.LightEffectOptions | null | undefined {
    const configured = ImmersiveMaterialRuntime.configuredLightLevel();
    if (configured === 'high') return { color: '#88FFFFFF' };
    if (configured === 'balanced') return { color: '#55FFFFFF' };
    if (configured === 'weak') return null;
    // An undefined lightEffect means "do not enable light feedback" for a
    // component-level material. Stepper buttons opt in explicitly so the
    // default follow-system setting still provides the expected touch glow.
    if (forceAdaptive) return { color: '#55FFFFFF' };
    return undefined;
  }

  /**
   * Shared dropdown material. Select menus otherwise inherit device-specific
   * shadows on API 26+, which makes identical controls look different across
   * pages. Older devices keep the platform fallback by returning undefined.
   */
  /** A fresh instance per build pass, so a changed light-sense setting is applied again. */
  static selectMenuModifier(): SelectMenuMaterialModifier {
    return new SelectMenuMaterialModifier();
  }

  /**
   * 下拉弹出菜单（bindPopup）的沉浸光感材质：随光感档位的薄材质、带投影，光感取强调色。
   * API 26 以下返回 undefined，调用方退回磨砂底。
   */
  static popupMenuMaterial(accentColor: string): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialRuntime.supportsHds()) return undefined;
    return new uiMaterial.ImmersiveMaterial({
      style: ImmersiveMaterialRuntime.materialStyle(),
      applyShadow: true,
      interactive: false,
      lightEffect: { color: accentColor }
    });
  }

  /**
   * 下拉菜单统一用系统弹出层：API 26+ 背景是沉浸光感材质，旧系统退回半透明磨砂；
   * 点菜单外自动收起，收起时回调让调用方复位开关。builder 用箭头函数传入，保证其中的 this 指向页面。
   */
  static popupMenuOptions(builder: CustomBuilder, placement: Placement, darkMode: boolean, accentColor: string,
    onHidden: () => void): CustomPopupOptions {
    const material = ImmersiveMaterialRuntime.popupMenuMaterial(accentColor);
    const options: CustomPopupOptions = {
      builder: builder,
      placement: placement,
      popupColor: material !== undefined ? Color.Transparent : ThemeRuntime.glassPanelColor(darkMode, '', 'panel'),
      radius: ImmersiveMaterialRuntime.POPUP_MENU_RADIUS,
      enableArrow: false,
      targetSpace: 8,
      focusable: true,
      onStateChange: (event) => {
        if (!event.isVisible) {
          onHidden();
        }
      }
    };
    if (material !== undefined) {
      options.systemMaterial = material;
    } else {
      options.backgroundBlurStyle = BlurStyle.COMPONENT_THICK;
    }
    return options;
  }

  private static tagMaterials: Map<string, uiMaterial.ImmersiveMaterial> = new Map<string, uiMaterial.ImmersiveMaterial>();

  /**
   * 标签材质按颜色、光感档位与深浅模式缓存，列表里大量标签共用同一个实例。
   * 组件级材质只要 API 26 就能绘制，不依赖设备的沉浸能力查询结果。
   */
  static tagMaterial(lightColor: string, darkMode: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (deviceInfo.sdkApiVersion < 26 || !/^#[0-9A-Fa-f]{6}$/.test(lightColor)) return undefined;
    const style = ImmersiveMaterialRuntime.materialStyle();
    const key = `${lightColor}|${style}|${darkMode ? 'dark' : 'light'}`;
    const cached = ImmersiveMaterialRuntime.tagMaterials.get(key);
    if (cached !== undefined) return cached;
    const material = new uiMaterial.ImmersiveMaterial({
      style: style,
      materialColor: `${darkMode ? '#26' : '#14'}${lightColor.substring(1)}`,
      applyShadow: false,
      interactive: true,
      lightEffect: { color: lightColor }
    });
    ImmersiveMaterialRuntime.tagMaterials.set(key, material);
    return material;
  }

  static selectMenuMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialRuntime.supportsHds()) return undefined;
    return new uiMaterial.ImmersiveMaterial({
      style: ImmersiveMaterialRuntime.materialStyle(),
      materialColor: '#00000000',
      applyShadow: false,
      interactive: ImmersiveMaterialRuntime.configuredLightLevel() !== 'weak',
      lightEffect: ImmersiveMaterialRuntime.lightEffect()
    });
  }
}
