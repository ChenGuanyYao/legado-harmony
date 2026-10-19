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
 * 彩色标签的玻璃胶囊：标签原浅底色上叠一层自上而下的高光渐变、一圈同色系半透明细边，
 * 再用标签文字色做很淡的柔和投影，让标签像悬浮栏的沉浸材质那样有反光、轮廓和浮起感。
 * 组件级系统材质放在不透明卡片里没有可透出的内容，几乎看不见，所以这里直接画出这三层，
 * 各系统版本效果一致。文字颜色由调用处照旧设置，按序号配色的规则不变。
 */
export class ImmersiveTagModifier implements AttributeModifier<CommonAttribute> {
  static readonly CAPSULE_RADIUS: number = 999;
  private surfaceColor: string;
  private lightColor: string;
  private darkMode: boolean;

  /**
   * @param surfaceColor 标签原本的浅底色
   * @param lightColor 标签文字色，用于边缘与投影的色调
   */
  constructor(surfaceColor: string, lightColor: string, darkMode: boolean) {
    this.surfaceColor = surfaceColor;
    this.lightColor = lightColor;
    this.darkMode = darkMode;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    const surface = ImmersiveTagModifier.isHex(this.surfaceColor) ? this.surfaceColor : '#F0F0F0';
    // 顶部向白色提亮，模拟玻璃上沿的反光；深色模式提亮幅度小一些。
    const highlight = ImmersiveTagModifier.mixWithWhite(surface, this.darkMode ? 0.14 : 0.7);
    instance.linearGradient({
      direction: GradientDirection.Bottom,
      colors: [[highlight, 0], [surface, 0.62], [surface, 1]]
    });
    if (ImmersiveTagModifier.isHex(this.lightColor)) {
      const tone = this.lightColor.substring(1);
      instance.border({ width: 0.75, color: `${this.darkMode ? '#4D' : '#3D'}${tone}` });
      instance.shadow({
        radius: 6,
        color: `${this.darkMode ? '#33' : '#2E'}${tone}`,
        offsetX: 0,
        offsetY: 2
      });
    }
    // 胶囊形：圆角超过高度一半时按一半绘制。
    instance.borderRadius(ImmersiveTagModifier.CAPSULE_RADIUS);
  }

  private static isHex(color: string): boolean {
    return /^#[0-9A-Fa-f]{6}$/.test(color);
  }

  private static mixWithWhite(hex: string, ratio: number): string {
    const channel = (start: number): string => {
      const value = parseInt(hex.substring(start, start + 2), 16);
      const mixed = Math.round(value + (255 - value) * ratio);
      return mixed.toString(16).padStart(2, '0').toUpperCase();
    };
    return `#${channel(1)}${channel(3)}${channel(5)}`;
  }
}

/**
 * 玻璃标签：放在有图像的背景上（如模糊封面行、详情页氛围背景）时使用。
 * API 26+ 用透明的组件级沉浸材质叠一层半透明白（深色模式为深色玻璃），交互光感取标签文字色；
 * 旧系统画半透明白底加细边。文字颜色由调用处设置，按序号配色不变。
 */
export class GlassTagModifier implements AttributeModifier<CommonAttribute> {
  private lightColor: string;
  private darkMode: boolean;

  /** @param lightColor 标签文字色，用作交互光感颜色 */
  constructor(lightColor: string, darkMode: boolean) {
    this.lightColor = lightColor;
    this.darkMode = darkMode;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    const material = ImmersiveMaterialRuntime.glassTagMaterial(this.lightColor, this.darkMode);
    if (material !== undefined) {
      instance.backgroundColor(Color.Transparent);
      instance.systemMaterial(material);
      // 离屏合成会把材质压成平面，保持逐层绘制。
      instance.renderGroup(false);
    } else {
      instance.backgroundColor(this.darkMode ? '#4D1B1D22' : '#B3FFFFFF');
      instance.border({ width: 0.5, color: this.darkMode ? '#26FFFFFF' : '#14000000' });
      instance.shadow({ radius: 6, color: this.darkMode ? '#33000000' : '#14000000', offsetX: 0, offsetY: 2 });
    }
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
    onHidden: () => void, focusable: boolean = true): CustomPopupOptions {
    const material = ImmersiveMaterialRuntime.popupMenuMaterial(accentColor);
    const options: CustomPopupOptions = {
      builder: builder,
      placement: placement,
      popupColor: material !== undefined ? Color.Transparent : ThemeRuntime.glassPanelColor(darkMode, '', 'panel'),
      radius: ImmersiveMaterialRuntime.POPUP_MENU_RADIUS,
      enableArrow: false,
      targetSpace: 8,
      // 跟着输入框弹出的面板传 false，免得抢走焦点收起键盘。
      focusable: focusable,
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

  private static glassTagMaterials: Map<string, uiMaterial.ImmersiveMaterial> =
    new Map<string, uiMaterial.ImmersiveMaterial>();

  /** 玻璃标签材质按光感颜色、光感档位与深浅模式缓存；组件级材质只要 API 26 就能绘制。 */
  static glassTagMaterial(lightColor: string, darkMode: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (deviceInfo.sdkApiVersion < 26) return undefined;
    const light = /^#[0-9A-Fa-f]{6}$/.test(lightColor) ? lightColor : '#FFFFFF';
    const style = ImmersiveMaterialRuntime.materialStyle();
    const key = `${light}|${style}|${darkMode ? 'dark' : 'light'}`;
    const cached = ImmersiveMaterialRuntime.glassTagMaterials.get(key);
    if (cached !== undefined) return cached;
    const material = new uiMaterial.ImmersiveMaterial({
      style: style,
      materialColor: darkMode ? '#401B1D22' : '#66FFFFFF',
      applyShadow: true,
      interactive: true,
      lightEffect: { color: light }
    });
    ImmersiveMaterialRuntime.glassTagMaterials.set(key, material);
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
