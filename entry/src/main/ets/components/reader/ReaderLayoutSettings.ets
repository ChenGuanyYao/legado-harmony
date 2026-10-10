import { ImmersiveMaterialRuntime } from '../../utils/ImmersiveMaterialRuntime';
import { ImmersiveBackButton } from '../ImmersiveBackButton';
import { ThemeRuntime } from '../../theme/ThemeRuntime';

/** 排版参数在草稿数组里的下标。 */
export class ReaderTypographyField {
  static readonly FONT_SIZE: number = 0;
  static readonly LETTER_SPACING: number = 1;
  static readonly LINE_HEIGHT: number = 2;
  static readonly PARAGRAPH_SPACING: number = 3;
  static readonly MARGIN_LEFT: number = 4;
  static readonly MARGIN_RIGHT: number = 5;
  static readonly MARGIN_TOP: number = 6;
  static readonly MARGIN_BOTTOM: number = 7;
  static readonly COUNT: number = 8;

  static readonly LABELS: string[] = ['字号', '字距', '行距', '段落间距', '左边距', '右边距', '上边距', '下边距'];

  static min(field: number): number {
    return field === ReaderTypographyField.FONT_SIZE ? 14 : 0;
  }

  static max(field: number): number {
    if (field === ReaderTypographyField.FONT_SIZE) return 50;
    if (field === ReaderTypographyField.LETTER_SPACING) return 8;
    if (field === ReaderTypographyField.LINE_HEIGHT) return 52;
    if (field === ReaderTypographyField.PARAGRAPH_SPACING) return 32;
    if (field === ReaderTypographyField.MARGIN_LEFT || field === ReaderTypographyField.MARGIN_RIGHT) return 80;
    return 120;
  }

  static clamp(field: number, value: number): number {
    return Math.max(ReaderTypographyField.min(field), Math.min(Math.round(value), ReaderTypographyField.max(field)));
  }
}

/**
 * 正文排版的统一调节控件：下拉选一个参数（字号、字距、行距、段距、四侧边距），用加减按钮或直接输入数值。
 * 数值草稿是组件自己的状态，连点加减只刷新这个控件；每次变化把整组草稿交给页面，
 * 页面稍后一次性提交并重排正文。
 */
@Component
export struct ReaderTypographyStepper {
  /** 打开时的初始值，顺序见 ReaderTypographyField。 */
  initialValues: number[] = [];
  @Prop dark: boolean = false;
  @Prop textColor: string = '#202124';
  @Prop subTextColor: string = '#80868B';
  @Prop accentColor: string = '#0A59F7';
  @Prop inputColor: string = '#FFFFFF';
  @Prop menuColor: string = '#FFFFFF';
  onChange: (values: number[]) => void = (_values: number[]): void => {
  };

  @State private field: number = 0;
  @State private values: number[] = [];
  @State private inputVisible: boolean = false;
  @State private inputDraft: string = '';

  aboutToAppear(): void {
    const values: number[] = [];
    for (let field = 0; field < ReaderTypographyField.COUNT; field++) {
      values.push(field < this.initialValues.length ? this.initialValues[field] : ReaderTypographyField.min(field));
    }
    this.values = values;
  }

  private current(): number {
    return this.field < this.values.length ? this.values[this.field] : 0;
  }

  private apply(value: number): void {
    const next = [...this.values];
    next[this.field] = ReaderTypographyField.clamp(this.field, value);
    this.values = next;
    this.onChange([...next]);
  }

  private applyInput(): void {
    if (!this.inputVisible) return;
    const value = Number(this.inputDraft);
    if (this.inputDraft.trim() && Number.isFinite(value)) this.apply(value);
    this.inputVisible = false;
  }

  build() {
    Row({ space: 8 }) {
      Select(ReaderTypographyField.LABELS.map((label: string): SelectOption => ({ value: label })))
        .id('reader_typography_selector')
        .selected(this.field)
        .value(ReaderTypographyField.LABELS[this.field])
        .font({ size: 15 })
        .fontColor(this.subTextColor)
        .backgroundColor(Color.Transparent)
        .arrowPosition(ArrowPosition.START)
        .padding({ left: 0, right: 0 })
        .borderRadius(16)
        .border({ width: 0 })
        .optionBgColor(Color.Transparent)
        .divider(null)
        .optionFontColor(this.textColor)
        .selectedOptionFontColor(this.accentColor)
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.dark))
        .menuBackgroundColor(this.menuColor)
        .menuBackgroundBlurStyle(BlurStyle.NONE)
        .menuSystemMaterial(ImmersiveMaterialRuntime.selectMenuMaterial())
        .onSelect((index: number) => {
          this.inputVisible = false;
          this.field = Math.max(0, Math.min(index, ReaderTypographyField.COUNT - 1));
        })
      Blank()
        .layoutWeight(1)
      this.stepButton($r('sys.symbol.minus'), '减小当前排版参数',
        this.current() > ReaderTypographyField.min(this.field), () => this.apply(this.current() - 1))
      if (this.inputVisible) {
        TextInput({ text: this.inputDraft, placeholder: `${this.current()}` })
          .type(InputType.Number)
          .enterKeyType(EnterKeyType.Done)
          .defaultFocus(true)
          .fontSize(15)
          .fontColor(this.textColor)
          .width(52)
          .height(36)
          .padding(0)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.inputColor)
          .borderRadius(6)
          .onChange((value: string) => {
            this.inputDraft = value.replace(/[^0-9]/g, '').substring(0, 3);
          })
          .onSubmit(() => this.applyInput())
          .onBlur(() => this.applyInput())
      } else {
        Text(`${Math.round(this.current())}`)
          .fontSize(15)
          .fontColor(this.textColor)
          .width(52)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.inputDraft = '';
            this.inputVisible = true;
          })
      }
      this.stepButton($r('sys.symbol.plus'), '增大当前排版参数',
        this.current() < ReaderTypographyField.max(this.field), () => this.apply(this.current() + 1))
    }
    .width('100%')
    // Keep the selector on the same content baseline as the settings below.
    .padding({ left: 0, right: 0, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  stepButton(icon: Resource, accessibilityText: string, enabled: boolean, action: () => void) {
    ImmersiveBackButton({
      icon: icon,
      accessibilityLabel: accessibilityText,
      iconColor: this.dark ? '#FFFFFFFF' : '#FF202124',
      disabledIconColor: this.subTextColor,
      darkMode: this.dark,
      buttonEnabled: enabled,
      buttonSize: 34,
      containerWidth: 34,
      containerHeight: 34,
      startInset: 0,
      compactLayout: true,
      onBack: action
    })
  }
}

/**
 * 页眉页脚设置组。几个开关和选项直接绑定全局设置；
 * 阅读页监听同一组设置，负责保存并按需重排正文，这里不需要任何回调。
 */
@Component
export struct ReaderHeaderFooterSettings {
  @Prop dark: boolean = false;
  @Prop textColor: string = '#202124';
  @Prop subTextColor: string = '#80868B';
  @Prop accentColor: string = '#0A59F7';
  @Prop switchColor: string = '#0A59F7';
  @Prop menuColor: string = '#FFFFFF';
  @StorageLink('readerHeaderEnabled') readerHeaderEnabled: boolean = false;
  @StorageLink('readerHeaderContentMode') readerHeaderContentMode: string = 'chapter';
  @StorageLink('readerFooterEnabled') readerFooterEnabled: boolean = true;
  @StorageLink('readerFooterLeftMode') readerFooterLeftMode: string = 'chapter';
  @StorageLink('readerFooterProgressMode') readerFooterProgressMode: string = 'page';
  @StorageLink('readerFooterShowProgressBar') readerFooterShowProgressBar: boolean = false;

  private static readonly HEADER_VALUES: string[] = ['chapter', 'book', 'book_chapter', 'none'];
  private static readonly HEADER_LABELS: string[] = ['当前章节标题', '书名', '书名 + 章节标题', '不显示'];
  private static readonly FOOTER_LEFT_VALUES: string[] = ['chapter', 'title', 'none'];
  private static readonly FOOTER_LEFT_LABELS: string[] = ['章节序号 + 标题', '章节标题', '不显示'];
  private static readonly PROGRESS_VALUES: string[] = ['page', 'percentage', 'chapter', 'book', 'none'];
  private static readonly PROGRESS_LABELS: string[] = ['当前页 / 总页数', '阅读百分比', '章节进度', '全书进度', '不显示'];

  private indexOf(values: string[], value: string): number {
    const index = values.indexOf(value);
    return index >= 0 ? index : 0;
  }

  build() {
    Column({ space: 4 }) {
      this.switchItem('显示页眉', '在正文顶部显示书名或当前章节标题', this.readerHeaderEnabled,
        (checked: boolean) => {
          this.readerHeaderEnabled = checked;
        })

      if (this.readerHeaderEnabled) {
        this.selectItem('页眉内容', '选择页眉中显示的信息', ReaderHeaderFooterSettings.HEADER_LABELS,
          this.indexOf(ReaderHeaderFooterSettings.HEADER_VALUES, this.readerHeaderContentMode),
          (index: number) => {
            const values = ReaderHeaderFooterSettings.HEADER_VALUES;
            this.readerHeaderContentMode = index >= 0 && index < values.length ? values[index] : 'chapter';
          }, 'reader_header_content_select')
      }

      this.switchItem('显示页脚', '显示章节信息和阅读进度', this.readerFooterEnabled, (checked: boolean) => {
        this.readerFooterEnabled = checked;
      })

      if (this.readerFooterEnabled) {
        this.selectItem('页脚左侧', '选择页脚左侧显示的信息', ReaderHeaderFooterSettings.FOOTER_LEFT_LABELS,
          this.indexOf(ReaderHeaderFooterSettings.FOOTER_LEFT_VALUES, this.readerFooterLeftMode),
          (index: number) => {
            const values = ReaderHeaderFooterSettings.FOOTER_LEFT_VALUES;
            this.readerFooterLeftMode = index >= 0 && index < values.length ? values[index] : 'chapter';
          }, 'reader_footer_left_select')

        this.selectItem('阅读进度', '选择页脚右侧显示的进度类型', ReaderHeaderFooterSettings.PROGRESS_LABELS,
          this.indexOf(ReaderHeaderFooterSettings.PROGRESS_VALUES, this.readerFooterProgressMode),
          (index: number) => {
            const values = ReaderHeaderFooterSettings.PROGRESS_VALUES;
            this.readerFooterProgressMode = index >= 0 && index < values.length ? values[index] : 'page';
          }, 'reader_footer_progress_select')

        this.switchItem('显示进度条', '在页脚上方显示本章阅读进度', this.readerFooterShowProgressBar,
          (checked: boolean) => {
            this.readerFooterShowProgressBar = checked;
          })
      }
    }
    .width('100%')
    .padding({ bottom: 8 })
  }

  @Builder
  itemLabel(title: string, description: string) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontColor(this.textColor)
      Text(description)
        .fontSize(12)
        .fontColor(this.subTextColor)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  switchItem(title: string, description: string, checked: boolean, onChange: (checked: boolean) => void) {
    Row() {
      this.itemLabel(title, description)
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(this.switchColor)
        .onChange((value: boolean) => onChange(value))
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  selectItem(title: string, description: string, labels: string[], selected: number,
    onSelect: (index: number) => void, controlId: string) {
    Row() {
      this.itemLabel(title, description)
      Select(labels.map((label: string): SelectOption => ({ value: label })))
        .id(controlId)
        .selected(selected)
        .value(selected >= 0 && selected < labels.length ? labels[selected] : (labels.length > 0 ? labels[0] : ''))
        .font({ size: 14 })
        .fontColor(this.subTextColor)
        .backgroundColor(Color.Transparent)
        .arrowPosition(ArrowPosition.END)
        .padding({ left: 0, right: 0 })
        // Keep the hit area rectangular, but soften its corners to match the rounded settings cards.
        .borderRadius(16)
        .border({ width: 0 })
        .optionBgColor(Color.Transparent)
        .divider(null)
        .optionFontColor(this.textColor)
        .selectedOptionFontColor(this.accentColor)
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.dark))
        .menuBackgroundColor(this.menuColor)
        .menuBackgroundBlurStyle(BlurStyle.NONE)
        .menuSystemMaterial(ImmersiveMaterialRuntime.selectMenuMaterial())
        .onSelect((index: number) => onSelect(index))
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
  }
}
