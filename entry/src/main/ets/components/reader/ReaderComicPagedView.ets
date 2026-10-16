import { LocalBookService } from '../../core/book/LocalBookService';
import { AppFontSize } from '../../theme/AppFontSize';
import { AppSpacing } from '../../theme/AppSpacing';
import { ReaderImageMarker } from '../../core/book/ReaderImageMarker';
import { ReaderComicImageItem, ReaderComicImageSizes, ReaderComicInfoBadge, ReaderComicRetryRegistry } from './ReaderComicView';

/** 阅读页向翻页视图发出的指令（点击翻页、音量键）；视图挂载时填入实现。 */
export class ReaderComicPagedController {
  turn: (direction: number) => void = () => {};
}

/**
 * 漫画单页翻页视图。宽屏时两页并排为一个跨页；右→左模式下“下一页”在左边。
 * 只渲染当前跨页和左右各一个：越过本章首尾时那一格显示章节提示卡，松手后由阅读页切章。
 * 当前页码以阅读页的 pageIndex 为准，视图翻完一页后通过 onPageChanged 回报跨页首页。
 */
@Component
export struct ReaderComicPagedView {
  controller: ReaderComicPagedController = new ReaderComicPagedController();
  @Prop @Watch('onLayoutChanged') pages: string[] = [];
  @Prop @Watch('onPageIndexChanged') pageIndex: number = 0;
  @Prop @Watch('onLayoutChanged') chapterIndex: number = 0;
  @Prop @Watch('onLayoutChanged') viewWidth: number = 0;
  @Prop viewHeight: number = 0;
  @Prop @Watch('onLayoutChanged') dualPage: boolean = false;
  @Prop rightToLeft: boolean = false;
  @Prop doubleTapZoom: boolean = true;
  @Prop surfaceColor: string = '#000000';
  @Prop textColor: string = '#E6E6E6';
  @Prop hintColor: string = '#99FFFFFF';
  @Prop interactive: boolean = true;
  @Prop panDistance: number = 12;
  @Prop transitionOpacity: number = 1;
  /** 相邻章节标题；空串表示该方向没有章节。 */
  @Prop prevChapterTitle: string = '';
  @Prop nextChapterTitle: string = '';
  @Prop infoVisible: boolean = false;
  @Prop infoChapter: string = '';
  @Prop infoPage: string = '';
  @Prop infoTime: string = '';
  @Prop infoBattery: number = -1;
  @Prop infoBottomInset: number = 6;
  /** 网络图片向后预先加载的页数。 */
  @Prop preloadCount: number = 5;
  onImageLongPress: (source: string, reload: () => void, snapshotId: string) => void = () => {};
  onImageDenied: (chapterIndex: number) => void = () => {};
  onPageChanged: (pageIndex: number) => void = () => {};
  /** 越过本章首尾：1 为下一话，-1 为上一话。 */
  onBoundary: (direction: number) => void = () => {};
  /** 坐标相对视图左上角。 */
  onTap: (x: number, y: number, width: number, height: number) => void = () => {};
  static readonly MAX_ZOOM: number = 4;
  static readonly DOUBLE_TAP_ZOOM: number = 2;
  @State private spreadIndex: number = 0;
  @State private dragOffset: number = 0;
  @State private zoomScale: number = 1;
  @State private zoomX: number = 0;
  @State private zoomY: number = 0;
  private retryRegistry: ReaderComicRetryRegistry = new ReaderComicRetryRegistry();
  private animating: boolean = false;
  private touchDragged: boolean = false;
  private pinching: boolean = false;
  private pinchBaseScale: number = 1;
  private pinchBaseX: number = 0;
  private pinchBaseY: number = 0;
  private pinchFocusX: number = 0;
  private pinchFocusY: number = 0;
  private zoomPanActive: boolean = false;
  private panLastX: number = 0;
  private panLastY: number = 0;
  private panResync: boolean = false;

  aboutToAppear(): void {
    this.spreadIndex = this.spreadOf(this.pageIndex);
    this.controller.turn = (direction: number): void => this.turn(direction);
  }

  aboutToDisappear(): void {
    this.controller.turn = () => {};
  }

  onLayoutChanged(): void {
    this.dragOffset = 0;
    this.applyZoom(1, 0, 0);
    this.spreadIndex = this.spreadOf(this.pageIndex);
  }

  onPageIndexChanged(): void {
    if (this.animating) return;
    const target = this.spreadOf(this.pageIndex);
    if (target === this.spreadIndex) return;
    this.dragOffset = 0;
    this.applyZoom(1, 0, 0);
    this.spreadIndex = target;
  }

  private spreadSize(): number {
    return this.dualPage ? 2 : 1;
  }

  private spreadCount(): number {
    return Math.ceil(this.pages.length / this.spreadSize());
  }

  private spreadOf(pageIndex: number): number {
    const count = this.spreadCount();
    if (count <= 0) return 0;
    return Math.max(0, Math.min(count - 1, Math.floor(Math.max(0, pageIndex) / this.spreadSize())));
  }

  /** 跨页内的页码，按屏幕从左到右排列。 */
  private spreadPages(spread: number): number[] {
    const result: number[] = [];
    const first = spread * this.spreadSize();
    for (let page = first; page < Math.min(this.pages.length, first + this.spreadSize()); page++) {
      result.push(page);
    }
    return this.rightToLeft ? result.reverse() : result;
  }

  private viewW(): number {
    return Math.max(1, this.viewWidth);
  }

  private viewH(): number {
    return Math.max(1, this.viewHeight);
  }

  /** 第 k 个相邻跨页（k = 跨页序号 − 当前序号）在屏幕上的横向位置。 */
  private slotX(spread: number): number {
    const k = spread - this.spreadIndex;
    return (this.rightToLeft ? -k : k) * this.viewW() + this.dragOffset;
  }

  /** 翻到 direction 方向时当前跨页要移到的位置。 */
  private turnOffset(direction: number): number {
    return (this.rightToLeft ? direction : -direction) * this.viewW();
  }

  /** 手指横向位移对应的阅读方向：左→右模式向左拖是下一页，右→左模式相反。 */
  private dragDirection(offsetX: number): number {
    if (offsetX === 0) return 0;
    const leftward = offsetX < 0;
    return this.rightToLeft ? (leftward ? -1 : 1) : (leftward ? 1 : -1);
  }

  private hasChapter(direction: number): boolean {
    return direction > 0 ? !!this.nextChapterTitle : !!this.prevChapterTitle;
  }

  private turn(direction: number): void {
    if (this.animating || this.pages.length === 0 || direction === 0) return;
    const target = this.spreadIndex + direction;
    if (target < 0 || target >= this.spreadCount()) {
      this.onBoundary(direction);
      return;
    }
    this.applyZoom(1, 0, 0);
    this.animateTurn(direction);
  }

  private animateTurn(direction: number): void {
    this.animating = true;
    animateTo({
      duration: 240,
      curve: Curve.Friction,
      onFinish: () => this.finishTurn(direction)
    }, () => {
      this.dragOffset = this.turnOffset(direction);
    });
  }

  private finishTurn(direction: number): void {
    // 先换当前序号再归零位移：相邻格按新序号重新定位后恰好落在动画终点，不会闪动。
    this.spreadIndex = Math.max(0, Math.min(this.spreadCount() - 1, this.spreadIndex + direction));
    this.dragOffset = 0;
    this.animating = false;
    this.onPageChanged(this.spreadIndex * this.spreadSize());
  }

  private settleBack(): void {
    if (this.dragOffset === 0) return;
    this.animating = true;
    animateTo({
      duration: 200,
      curve: Curve.Friction,
      onFinish: () => {
        this.animating = false;
      }
    }, () => {
      this.dragOffset = 0;
    });
  }

  private zoomed(): boolean {
    return this.zoomScale > 1.001;
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  private applyZoom(scale: number, x: number, y: number): void {
    let nextScale = this.clamp(scale, 1, ReaderComicPagedView.MAX_ZOOM);
    if (nextScale <= 1.001) nextScale = 1;
    const boundX = (nextScale - 1) * this.viewW() / 2;
    const boundY = (nextScale - 1) * this.viewH() / 2;
    this.zoomScale = nextScale;
    this.zoomX = this.clamp(x, -boundX, boundX);
    this.zoomY = this.clamp(y, -boundY, boundY);
  }

  /** 把缩放前位于 origin 的点放到 focus 处，同时从 base 状态缩放到 nextScale。 */
  private zoomAround(focusX: number, focusY: number, originX: number, originY: number, baseScale: number,
    baseX: number, baseY: number, nextScale: number): void {
    const scale = this.clamp(nextScale, 1, ReaderComicPagedView.MAX_ZOOM);
    const ratio = scale / Math.max(0.001, baseScale);
    const centerX = this.viewW() / 2;
    const centerY = this.viewH() / 2;
    this.applyZoom(scale, focusX - centerX - ratio * (originX - centerX - baseX),
      focusY - centerY - ratio * (originY - centerY - baseY));
  }

  private tapPoint(event: GestureEvent): number[] {
    const finger = event.fingerList && event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    return finger ? [finger.localX, finger.localY] : [this.viewW() / 2, this.viewH() / 2];
  }

  private retryKey(pageIndex: number): string {
    return `${this.chapterIndex}_${pageIndex}`;
  }

  private handleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down && event.touches.length <= 1) this.touchDragged = false;
  }

  private handleDoubleTap(event: GestureEvent): void {
    if (this.touchDragged || this.animating) return;
    if (this.zoomed()) {
      animateTo({ duration: 220, curve: Curve.Friction }, () => this.applyZoom(1, 0, 0));
      return;
    }
    const point = this.tapPoint(event);
    animateTo({ duration: 220, curve: Curve.Friction }, () => {
      this.zoomAround(point[0], point[1], point[0], point[1], 1, 0, 0, ReaderComicPagedView.DOUBLE_TAP_ZOOM);
    });
  }

  /** 按阅读方向排在当前跨页之后、需要预先下载的网络图片地址。 */
  private prefetchSources(): string[] {
    const result: string[] = [];
    const first = (this.spreadIndex + 2) * this.spreadSize();
    for (let page = first; page < Math.min(this.pages.length, first + this.preloadCount); page++) {
      const text = (this.pages[page] || '').trim();
      if (!LocalBookService.isEpubImageMarker(text)) continue;
      const source = ReaderImageMarker.parse(text).source;
      if (ReaderComicImageSizes.isRemote(source)) result.push(source);
    }
    return result;
  }

  private handleLongPress(event: GestureEvent): void {
    if (this.pinching || this.animating) return;
    this.touchDragged = true;
    const point = this.tapPoint(event);
    const centerX = this.viewW() / 2;
    const slotX = centerX + (point[0] - centerX - this.zoomX) / this.zoomScale;
    const pages = this.spreadPages(this.spreadIndex);
    if (pages.length === 0) return;
    const boxWidth = this.viewW() / pages.length;
    const pageIndex = pages[Math.max(0, Math.min(pages.length - 1, Math.floor(slotX / boxWidth)))];
    const text = (this.pages[pageIndex] || '').trim();
    if (!LocalBookService.isEpubImageMarker(text)) return;
    const key = this.retryKey(pageIndex);
    this.onImageLongPress(ReaderImageMarker.parse(text).source, (): void => this.retryRegistry.reload(key),
      ReaderComicImageItem.snapshotId(key));
  }

  private handleSingleTap(event: GestureEvent): void {
    if (this.touchDragged || this.animating) return;
    const point = this.tapPoint(event);
    // 失败提示被交互层盖住：点中某页居中的提示文字才重试，其余位置交给阅读页翻页或呼出菜单。
    const centerX = this.viewW() / 2;
    const centerY = this.viewH() / 2;
    const slotX = centerX + (point[0] - centerX - this.zoomX) / this.zoomScale;
    const slotY = centerY + (point[1] - centerY - this.zoomY) / this.zoomScale;
    const pages = this.spreadPages(this.spreadIndex);
    if (pages.length > 0 && Math.abs(slotY - centerY) <= 44) {
      const boxWidth = this.viewW() / pages.length;
      const column = Math.max(0, Math.min(pages.length - 1, Math.floor(slotX / boxWidth)));
      const nearHint = Math.abs(slotX - (column + 0.5) * boxWidth) <= boxWidth * 0.35;
      if (nearHint && this.retryRegistry.retry(this.retryKey(pages[column]))) return;
    }
    this.onTap(point[0], point[1], this.viewW(), this.viewH());
  }

  private handlePinchStart(event: GestureEvent): void {
    if (this.animating) return;
    this.pinching = true;
    this.touchDragged = true;
    this.panResync = true;
    if (this.dragOffset !== 0) {
      this.dragOffset = 0;
    }
    this.zoomPanActive = true;
    this.pinchBaseScale = this.zoomScale;
    this.pinchBaseX = this.zoomX;
    this.pinchBaseY = this.zoomY;
    this.pinchFocusX = event.pinchCenterX;
    this.pinchFocusY = event.pinchCenterY;
  }

  private handlePinchUpdate(event: GestureEvent): void {
    if (!this.pinching) return;
    this.zoomAround(event.pinchCenterX, event.pinchCenterY, this.pinchFocusX, this.pinchFocusY,
      this.pinchBaseScale, this.pinchBaseX, this.pinchBaseY, this.pinchBaseScale * event.scale);
  }

  private handlePinchEnd(): void {
    if (!this.pinching) return;
    this.pinching = false;
    this.panResync = true;
    if (this.zoomScale < 1.05) {
      animateTo({ duration: 200, curve: Curve.Friction }, () => this.applyZoom(1, 0, 0));
    }
  }

  private handlePanStart(): void {
    this.touchDragged = true;
    this.panLastX = 0;
    this.panLastY = 0;
    this.panResync = false;
    this.zoomPanActive = this.zoomed() || this.pinching;
  }

  private handlePanUpdate(event: GestureEvent): void {
    if (this.animating) return;
    if (!this.zoomPanActive) {
      // 本章首尾外没有章节可去时加阻尼，提示卡只露出一部分。
      const direction = this.dragDirection(event.offsetX);
      const target = this.spreadIndex + direction;
      const outside = target < 0 || target >= this.spreadCount();
      this.dragOffset = outside && !this.hasChapter(direction) ? event.offsetX * 0.3 : event.offsetX;
      return;
    }
    if (this.pinching || this.panResync) {
      this.panLastX = event.offsetX;
      this.panLastY = event.offsetY;
      this.panResync = this.pinching;
      return;
    }
    const boundX = (this.zoomScale - 1) * this.viewW() / 2;
    const boundY = (this.zoomScale - 1) * this.viewH() / 2;
    this.zoomX = this.clamp(this.zoomX + event.offsetX - this.panLastX, -boundX, boundX);
    this.zoomY = this.clamp(this.zoomY + event.offsetY - this.panLastY, -boundY, boundY);
    this.panLastX = event.offsetX;
    this.panLastY = event.offsetY;
  }

  private handlePanEnd(event: GestureEvent): void {
    const zoomPan = this.zoomPanActive;
    this.zoomPanActive = false;
    if (zoomPan || this.animating) return;
    const offset = this.dragOffset;
    const direction = this.dragDirection(offset);
    const flung = Math.abs(event.velocityX) > 500 && Math.sign(event.velocityX) === Math.sign(offset);
    if (direction === 0 || (Math.abs(offset) < this.viewW() * 0.18 && !flung)) {
      this.settleBack();
      return;
    }
    const target = this.spreadIndex + direction;
    if (target >= 0 && target < this.spreadCount()) {
      this.animateTurn(direction);
      return;
    }
    this.settleBack();
    if (this.hasChapter(direction)) this.onBoundary(direction);
  }

  private handlePanCancel(): void {
    const zoomPan = this.zoomPanActive;
    this.zoomPanActive = false;
    if (!zoomPan) this.settleBack();
  }

  @Builder
  pageView(pageIndex: number, boxWidth: number) {
    if (LocalBookService.isEpubImageMarker((this.pages[pageIndex] || '').trim())) {
      ReaderComicImageItem({
        marker: (this.pages[pageIndex] || '').trim(),
        viewWidth: boxWidth,
        viewHeight: this.viewH(),
        boxWidth: boxWidth,
        boxHeight: this.viewH(),
        pageLabel: `${pageIndex + 1}`,
        hintColor: this.hintColor,
        retryKey: this.retryKey(pageIndex),
        retryRegistry: this.retryRegistry,
        onDenied: (): void => this.onImageDenied(this.chapterIndex)
      })
    } else {
      Text(LocalBookService.stripEpubImageMarkers(this.pages[pageIndex] || '').trim())
        .fontSize(AppFontSize.BODY_LARGE)
        .lineHeight(AppFontSize.BODY_LARGE * 1.7)
        .fontColor(this.textColor)
        .width(boxWidth)
        .height(this.viewH())
        .padding({ left: AppSpacing.XXXL, right: AppSpacing.XXXL, top: 56, bottom: 56 })
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  @Builder
  boundaryCard(direction: number) {
    Column({ space: AppSpacing.LG }) {
      Text(direction > 0 ? '本话完' : '本话开头')
        .fontSize(AppFontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor)
      if (this.hasChapter(direction)) {
        Text(direction > 0 ? '继续翻页进入下一话' : '继续翻页回到上一话')
          .fontSize(AppFontSize.BODY)
          .fontColor(this.hintColor)
        Text(direction > 0 ? this.nextChapterTitle : this.prevChapterTitle)
          .fontSize(AppFontSize.BODY_LARGE)
          .fontColor(this.textColor)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
      } else {
        Text(direction > 0 ? '已经是最后一话' : '已经是第一话')
          .fontSize(AppFontSize.BODY)
          .fontColor(this.hintColor)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 40, right: 40 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  slot(spread: number) {
    Stack() {
      if (spread < 0 || spread >= this.spreadCount()) {
        this.boundaryCard(spread < 0 ? -1 : 1)
      } else {
        Row() {
          ForEach(this.spreadPages(spread), (pageIndex: number) => {
            this.pageView(pageIndex, this.viewW() / this.spreadPages(spread).length)
          }, (pageIndex: number) => `${pageIndex}_${this.spreadPages(spread).length}`)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width(this.viewW())
    .height(this.viewH())
    .position({ x: this.slotX(spread), y: 0 })
    .scale(spread === this.spreadIndex ? { x: this.zoomScale, y: this.zoomScale } : { x: 1, y: 1 })
    .translate(spread === this.spreadIndex ? { x: this.zoomX, y: this.zoomY } : { x: 0, y: 0 })
  }

  @Builder
  interactionLayer(doubleTap: boolean) {
    if (doubleTap) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => this.handleTouch(event))
        .gesture(
          GestureGroup(GestureMode.Parallel,
            GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2, distanceThreshold: this.panDistance })
                .onAction((event: GestureEvent) => this.handleDoubleTap(event)),
              TapGesture({ count: 1, distanceThreshold: this.panDistance })
                .onAction((event: GestureEvent) => this.handleSingleTap(event))
            ),
            LongPressGesture({ duration: 500 })
              .onAction((event: GestureEvent) => this.handleLongPress(event)),
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => this.handlePinchStart(event))
              .onActionUpdate((event: GestureEvent) => this.handlePinchUpdate(event))
              .onActionEnd(() => this.handlePinchEnd())
              .onActionCancel(() => this.handlePinchEnd()),
            PanGesture({ direction: PanDirection.All, distance: this.panDistance })
              .onActionStart(() => this.handlePanStart())
              .onActionUpdate((event: GestureEvent) => this.handlePanUpdate(event))
              .onActionEnd((event: GestureEvent) => this.handlePanEnd(event))
              .onActionCancel(() => this.handlePanCancel())
          )
        )
    } else {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => this.handleTouch(event))
        .gesture(
          GestureGroup(GestureMode.Parallel,
            TapGesture({ count: 1, distanceThreshold: this.panDistance })
              .onAction((event: GestureEvent) => this.handleSingleTap(event)),
            LongPressGesture({ duration: 500 })
              .onAction((event: GestureEvent) => this.handleLongPress(event)),
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => this.handlePinchStart(event))
              .onActionUpdate((event: GestureEvent) => this.handlePinchUpdate(event))
              .onActionEnd(() => this.handlePinchEnd())
              .onActionCancel(() => this.handlePinchEnd()),
            PanGesture({ direction: PanDirection.All, distance: this.panDistance })
              .onActionStart(() => this.handlePanStart())
              .onActionUpdate((event: GestureEvent) => this.handlePanUpdate(event))
              .onActionEnd((event: GestureEvent) => this.handlePanEnd(event))
              .onActionCancel(() => this.handlePanCancel())
          )
        )
    }
  }

  build() {
    Stack() {
      Stack() {
        ForEach([this.spreadIndex - 1, this.spreadIndex, this.spreadIndex + 1], (spread: number) => {
          this.slot(spread)
        }, (spread: number) => `${this.chapterIndex}_${this.spreadSize()}_${spread}`)
      }
      .width('100%')
      .height('100%')
      .opacity(this.transitionOpacity)

      // 预先下载后面几页的网络图片：1px 透明图片只为触发下载与缓存，autoResize 让解码也按 1px 进行。
      ForEach(this.prefetchSources(), (source: string) => {
        Image(source)
          .width(1)
          .height(1)
          .opacity(0)
          .autoResize(true)
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }, (source: string) => source)

      if (this.infoVisible) {
        ReaderComicInfoBadge({
          chapterText: this.infoChapter,
          pageText: this.infoPage,
          timeText: this.infoTime,
          battery: this.infoBattery
        })
          .position({ right: 10, bottom: this.infoBottomInset })
          .hitTestBehavior(HitTestMode.None)
      }

      if (this.interactive) {
        this.interactionLayer(this.doubleTapZoom)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.surfaceColor)
    .clip(true)
  }
}
