import image from '@ohos.multimedia.image';

/**
 * 卷曲起始区域，对应官方示例 EmulationFlipPage 的 DrawPosition。
 */
export enum ReaderEmulationFlipRegion {
  TOP = 0,
  MIDDLE = 1,
  BOTTOM = 2
}

interface FoldPoint {
  x: number;
  y: number;
}

interface FoldGeometry {
  a: FoldPoint;
  b: FoldPoint;
  c: FoldPoint;
  d: FoldPoint;
  e: FoldPoint;
  f: FoldPoint;
  h: FoldPoint;
  j: FoldPoint;
  k: FoldPoint;
  i: FoldPoint;
  leftShadowDistance: number;
  rightShadowDistance: number;
  topCorner: boolean;
  middleCorner: boolean;
}

/**
 * 仿真翻页（页角卷曲）绘制。
 *
 * 几何与明暗算法移植自 HarmonyOS 最佳实践《阅读器翻页》的官方示例
 * （HarmonyOS_Samples/PageFlip: EmulationFlipPage.ets + PageNodeController.ets + Constants.ets，
 * Apache-2.0）。原实现用 NodeContainer + RenderNode + @ohos.graphics.drawing 绘制；这里改用
 * 仓库既有的 Canvas 管线，几何点位、路径、阴影着色与官方保持一致。
 *
 * 与官方示例的差异：
 * 1. 官方由手指的页角坐标驱动，本实现由翻页进度驱动（进度 0 表示纸张平铺，1 表示完全翻出），
 *    起始区域仍按手指落点取上/中/下。
 * 2. 官方只在右侧卷曲；向前翻页时这里对整个画布做一次水平镜像，把折角移到左侧，仅在绘制纸张
 *    正面贴图时再抵消一次镜像，保证正文文字不被镜像。阴影旋转角仍按官方公式在原始坐标系中计算，
 *    这样镜像后不会出现错位的斜向阴影。
 * 3. 左右双页时翻动的是半页纸：先按官方几何把纸角卷起，进度后段让纸张绕书脊做几何位移
 *    （正面横向按 cos 压缩到书脊，背面再从书脊向另一列按 |cos| 展开），不使用淡入淡出。
 * 4. 纸背罩色、阴影和纸边描线由当前主题的纸张底色推导，不再使用官方固定的米黄与深灰，
 *    夜间主题下折页同样能看出层次。
 */
export class ReaderEmulationFlipPainter {
  // 对应 Constants.SIXTY_PERCENT。
  private readonly cornerRadiusRatio: number = 0.6;
  // 对应 drawPathAHorizontalShadow 中的 maxShadowWidth 与 +70。
  private readonly horizontalShadowMaxWidth: number = 30;
  private readonly horizontalShadowRightExtend: number = 70;
  private readonly finishedProgress: number = 0.995;
  // 页角点的总行程（页宽的倍数）。纸背一直画到折线为止，折线移出左边缘需要页角点越过左边缘
  // 约一个页宽；取 2.1 时折线在进度约 0.94 处从页面顶角扫出窗口，提交目标页时不会有残留的
  // 纸条突然消失。
  private readonly travelOvershoot: number = 2.1;
  // 双页：绕书脊的翻转从该进度开始，到进度 1 恰好转满 180°。
  private readonly doublePageSpineStart: number = 0.15;
  // 双页：卷角只轻轻卷起一点，主体运动交给绕书脊的翻转，避免纸面被折角切掉太多、
  // 正文看起来不跟着纸张走。
  private readonly doublePageFoldCap: number = 0.25;
  // 官方样例的绘制坐标是 px，本绘制器使用 vp；阴影的绝对像素常量需要按该比例换算。
  private vpPerPx: number = 1;
  // paperColor 为官方米黄兜底色；其余颜色由 applyPalette 按主题纸色推导。
  private readonly paperColor: string = 'rgb(255,235,195)';
  private activePaperColor: string = 'rgb(255,235,195)';
  private paletteKey: string = '';
  private darkPaper: boolean = false;
  private backTintColor: string = 'rgba(186,172,145,0.78)';
  private shadowDeepColor: string = 'rgba(17,17,17,0.5)';
  private shadowLightColor: string = 'rgba(17,17,17,0)';
  private shadowBackDeepColor: string = 'rgba(17,17,17,0.53)';
  private creaseShadowColor: string = 'rgba(17,17,17,0.42)';
  private edgeShadowColor: string = 'rgba(17,17,17,0.3)';
  private paperEdgeColor: string = 'rgba(0,0,0,0.1)';
  private highlightColor: string = 'rgba(255,255,255,0.1)';
  private highlightClearColor: string = 'rgba(255,255,255,0)';

  /**
   * 按主题纸色推导折页用色。纸背是纸色稍微压暗（夜间主题为提亮）后的不透明罩色，
   * 只隐约透出背面的镜像文字；夜间主题的阴影更重，并靠高光和纸边描线区分层次。
   */
  private applyPalette(paperColor: string, dark: boolean): void {
    const key = `${paperColor}_${dark ? 1 : 0}`;
    if (key === this.paletteKey) {
      return;
    }
    this.paletteKey = key;
    this.darkPaper = dark;
    const rgb = this.parseColor(paperColor);
    const shift = dark ? 22 : -16;
    const tintR = Math.max(0, Math.min(255, rgb[0] + shift));
    const tintG = Math.max(0, Math.min(255, rgb[1] + shift));
    const tintB = Math.max(0, Math.min(255, rgb[2] + shift));
    this.backTintColor = `rgba(${tintR},${tintG},${tintB},0.8)`;
    this.shadowDeepColor = dark ? 'rgba(0,0,0,0.72)' : 'rgba(17,17,17,0.5)';
    this.shadowLightColor = dark ? 'rgba(0,0,0,0)' : 'rgba(17,17,17,0)';
    this.shadowBackDeepColor = dark ? 'rgba(0,0,0,0.6)' : 'rgba(17,17,17,0.45)';
    this.creaseShadowColor = dark ? 'rgba(0,0,0,0.66)' : 'rgba(17,17,17,0.42)';
    this.edgeShadowColor = dark ? 'rgba(0,0,0,0.55)' : 'rgba(17,17,17,0.3)';
    this.paperEdgeColor = dark ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.12)';
    this.highlightColor = dark ? 'rgba(255,255,255,0.07)' : 'rgba(255,255,255,0.22)';
  }

  // 支持 #RGB、#RRGGBB、#AARRGGBB 与 rgb()/rgba()；无法识别时退回官方米黄。
  private parseColor(color: string): number[] {
    const fallback: number[] = [255, 235, 195];
    const value = (color || '').trim();
    if (value.startsWith('#')) {
      let hex = value.substring(1);
      if (hex.length === 3) {
        hex = `${hex.charAt(0)}${hex.charAt(0)}${hex.charAt(1)}${hex.charAt(1)}${hex.charAt(2)}${hex.charAt(2)}`;
      }
      if (hex.length === 8) {
        hex = hex.substring(2);
      }
      if (hex.length !== 6 || !/^[0-9a-fA-F]{6}$/.test(hex)) {
        return fallback;
      }
      return [parseInt(hex.substring(0, 2), 16), parseInt(hex.substring(2, 4), 16),
        parseInt(hex.substring(4, 6), 16)];
    }
    const matched = value.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i);
    if (matched) {
      return [Math.min(255, Number(matched[1])), Math.min(255, Number(matched[2])),
        Math.min(255, Number(matched[3]))];
    }
    return fallback;
  }

  draw(context: CanvasRenderingContext2D, page: image.PixelMap, backPage: image.PixelMap | null,
    canvasWidth: number, canvasHeight: number, progress: number, direction: number, region: number,
    doublePage: boolean, columnWidth: number, rightOrigin: number, vpPerPx: number,
    paperColor: string, dark: boolean): void {
    this.vpPerPx = vpPerPx > 0 ? vpPerPx : 1;
    // 折页背面必须用当前主题的纸张底色，否则会和页面底色不一致，看起来像另一块纸贴在上面。
    this.activePaperColor = paperColor && paperColor.length > 0 ? paperColor : this.paperColor;
    this.applyPalette(this.activePaperColor, dark);
    const width = Math.max(1, canvasWidth);
    const height = Math.max(1, canvasHeight);
    const curl = Math.max(0, Math.min(1, progress));
    context.clearRect(0, 0, width, height);
    context.imageSmoothingEnabled = true;
    if (!page) {
      return;
    }
    if (doublePage) {
      this.drawDoublePage(context, page, backPage, width, height, curl, direction, region,
        Math.max(1, columnWidth), rightOrigin);
      return;
    }
    if (curl <= 0.004 || curl >= this.finishedProgress) {
      // 平铺与翻出到底都不再需要卷曲层：前者直接铺满当前页，后者由底层目标页接管。
      if (curl <= 0.004) {
        context.drawImage(page, 0, 0, width, height);
      }
      return;
    }
    if (region === ReaderEmulationFlipRegion.MIDDLE && !doublePage) {
      // 中部起手：沿竖直折线把整页卷过去。
      this.drawVerticalFold(context, page, width, height, curl, direction);
      return;
    }
    const geometry = this.buildGeometry(width, height, curl, region);
    if (!geometry) {
      context.drawImage(page, 0, 0, width, height);
      return;
    }
    if (this.isFoldOutOfWindow(geometry, height)) {
      return;
    }
    // 向前翻页：整体水平镜像，把右侧折角搬到左侧。镜像变换是自逆的，绘制正文贴图时再应用一次即可抵消。
    const mirrored = direction < 0;
    context.save();
    if (mirrored) {
      context.translate(width, 0);
      context.scale(-1, 1);
    }
    this.drawPathBShadow(context, geometry, width, height);
    this.drawPathC(context, page, geometry, width, height);
    this.drawPathAContent(context, page, geometry, width, height, mirrored);
    context.restore();
  }

  /**
   * 左右双页：翻动的是半页纸。向后翻时右半页绕书脊向左翻，向前翻时整体水平镜像翻动左半页。
   * 官方几何是平面折角，无法表达"纸翻过去落在另一列"，因此进度后段叠加一次绕书脊的几何位移：
   * 正面按 cos 向书脊压缩，转过 90° 后背面页从书脊向另一列按 |cos| 展开；两者在书脊处宽度
   * 同时归零，交接连续，且全程是纯几何变换而非透明度过渡。
   */
  private drawDoublePage(context: CanvasRenderingContext2D, page: image.PixelMap, backPage: image.PixelMap | null,
    width: number, height: number, curl: number, direction: number, region: number, leafWidth: number,
    rightOrigin: number): void {
    const mirrored = direction < 0;
    // 书脊取整个对开页的中心，右半页绕它转到 180° 时正好铺满左列。
    const spineX = width / 2;
    const fraction = this.doublePageSpineFraction(curl);
    const cos = Math.cos(Math.PI * fraction);
    const foldCurl = Math.min(this.doublePageFoldCap, curl * 1.1);
    if (cos > 0.0005) {
      context.save();
      if (mirrored) {
        context.translate(width, 0);
        context.scale(-1, 1);
      }
      // 纸张只能出现在书脊右侧（镜像后为左侧），避免压到相邻页的正文。
      context.beginPath();
      context.rect(spineX, 0, width - spineX, height);
      context.clip();
      // 纸张抬起后在下层页面上的投影：贴着纸的外侧边，抬得越高越宽。
      const lift = Math.sin(Math.PI * fraction);
      const freeEdgeX = spineX + cos * (rightOrigin + leafWidth - spineX);
      this.fillHorizontalGradient(context, freeEdgeX, freeEdgeX + leafWidth * 0.14 * lift, 0, height,
        this.edgeShadowColor, this.shadowLightColor);
      // 绕书脊转动：横向按 cos 压缩，书脊是变换不动点。
      context.translate(spineX, 0);
      context.scale(cos, 1);
      context.translate(-spineX, 0);
      context.translate(rightOrigin, 0);
      if (foldCurl <= 0.004) {
        if (mirrored) {
          context.translate(leafWidth, 0);
          context.scale(-1, 1);
        }
        context.drawImage(page, 0, 0, leafWidth, height);
      } else {
        // 双页纸只有半页宽，官方竖折构造会退化，中部一并按底角折处理。
        const leafRegion = region === ReaderEmulationFlipRegion.MIDDLE ?
          ReaderEmulationFlipRegion.BOTTOM : region;
        const geometry = this.buildGeometry(leafWidth, height, foldCurl, leafRegion);
        if (!geometry) {
          if (mirrored) {
            context.translate(leafWidth, 0);
            context.scale(-1, 1);
          }
          context.drawImage(page, 0, 0, leafWidth, height);
        } else {
          this.drawPathBShadow(context, geometry, leafWidth, height);
          this.drawPathC(context, page, geometry, leafWidth, height);
          this.drawPathAContent(context, page, geometry, leafWidth, height, mirrored);
        }
      }
      // 纸面随转角背光变暗，转到 90° 时最暗；矩形关于列中线对称，不受上面抵消镜像的影响。
      context.fillStyle = `rgba(0,0,0,${(this.turnShadeStrength() * (1 - cos)).toFixed(3)})`;
      context.fillRect(0, 0, leafWidth, height);
      context.restore();
    } else if (backPage) {
      // 背面页从书脊向另一列展开：宽度为 |cos| 个列宽。
      // 书脊侧的边从书脊（90°）平滑过渡到落地列的边沿（180°），保证 180° 时与目标列严格对齐。
      const revealed = Math.min(leafWidth, -cos * leafWidth);
      if (revealed > 0.5) {
        const backFraction = Math.max(0, (fraction - 0.5) / 0.5);
        const lift = Math.sin(Math.PI * fraction);
        const shadowWidth = leafWidth * 0.14 * lift;
        const shade = `rgba(0,0,0,${(this.turnShadeStrength() * (1 + cos)).toFixed(3)})`;
        if (direction > 0) {
          const pinRight = spineX + (leafWidth - spineX) * backFraction;
          const left = pinRight - revealed;
          this.fillHorizontalGradient(context, left - shadowWidth, left, 0, height,
            this.shadowLightColor, this.edgeShadowColor);
          context.drawImage(backPage, left, 0, revealed, height);
          context.fillStyle = shade;
          context.fillRect(left, 0, revealed, height);
        } else {
          const pinLeft = spineX + (rightOrigin - spineX) * backFraction;
          const right = pinLeft + revealed;
          this.fillHorizontalGradient(context, right, right + shadowWidth, 0, height,
            this.edgeShadowColor, this.shadowLightColor);
          context.drawImage(backPage, pinLeft, 0, revealed, height);
          context.fillStyle = shade;
          context.fillRect(pinLeft, 0, revealed, height);
        }
      }
    }
  }

  // 双页纸张转到侧立时的最大压暗程度。
  private turnShadeStrength(): number {
    return this.darkPaper ? 0.42 : 0.26;
  }

  // 在 [left, right] 的竖条内从左到右填充一段水平线性渐变。
  private fillHorizontalGradient(context: CanvasRenderingContext2D, left: number, right: number, top: number,
    height: number, leftColor: string, rightColor: string): void {
    if (right - left <= 0.5) {
      return;
    }
    const gradient = context.createLinearGradient(left, 0, right, 0);
    gradient.addColorStop(0, leftColor);
    gradient.addColorStop(1, rightColor);
    context.fillStyle = gradient;
    context.fillRect(left, top, right - left, height);
  }

  private doublePageSpineFraction(progress: number): number {
    const value = Math.max(0, Math.min(1,
      (progress - this.doublePageSpineStart) / (1 - this.doublePageSpineStart)));
    return value * value * (3 - 2 * value);
  }

  private buildGeometry(width: number, height: number, progress: number, region: number): FoldGeometry | null {
    const radius = this.cornerRadiusRatio * width;
    // 起步时页角与进度 1:1 同行，后段逐渐加速，到进度 1 时走完 travelOvershoot 个页宽。
    const travel = progress * (1 + (this.travelOvershoot - 1) * progress * progress);
    const endX = (1 - this.travelOvershoot) * (width - 1);
    let ax = (1 - travel) * (width - 1);
    ax = Math.max(endX, Math.min(width - 1, ax));
    const topCorner = region === ReaderEmulationFlipRegion.TOP;
    const f: FoldPoint = { x: width, y: topCorner ? 0 : height };
    // 官方对"中部起手"把页角点固定在页面下边缘，折线会退化成一条垂直线，翻过去只剩一条竖窄条，
    // 不是正常翻折。这里始终按上/下角做带圆弧约束的斜向折角（对应 calcPointAByTouchPoint）。
    // 页角先沿圆弧抬到最高点，之后按余弦平滑回落到页边：折线逐渐立直并从侧边扫出窗口，
    // 不会像整段半圆那样在收尾处突然立直。
    const centerX = width - radius;
    let offset = 0;
    if (ax >= centerX) {
      offset = Math.sqrt(Math.max(0, radius * radius - (ax - centerX) * (ax - centerX)));
    } else {
      const fall = Math.min(1, (centerX - ax) / Math.max(1, centerX - endX));
      offset = radius * Math.cos(fall * Math.PI / 2);
    }
    const ay = Math.max(1, Math.min(height - 1, topCorner ? offset : height - offset));
    const middleCorner = false;
    const a: FoldPoint = { x: ax, y: ay };
    const g: FoldPoint = { x: (a.x + f.x) / 2, y: (a.y + f.y) / 2 };
    const denominatorE = f.x - g.x;
    const denominatorH = f.y - g.y;
    if (Math.abs(denominatorE) < 0.0001 || Math.abs(denominatorH) < 0.0001) {
      return null;
    }
    const e: FoldPoint = { x: g.x - (f.y - g.y) * (f.y - g.y) / denominatorE, y: f.y };
    const h: FoldPoint = { x: f.x, y: g.y - (f.x - g.x) * (f.x - g.x) / denominatorH };
    const c: FoldPoint = { x: e.x - (f.x - e.x) / 2, y: f.y };
    const j: FoldPoint = { x: f.x, y: h.y - (f.y - h.y) / 2 };
    const b = this.intersectionPoint(a, e, c, j);
    const k = this.intersectionPoint(a, h, c, j);
    const d: FoldPoint = { x: (c.x + 2 * e.x + b.x) / 4, y: (2 * e.y + c.y + b.y) / 4 };
    const i: FoldPoint = { x: (j.x + 2 * h.x + k.x) / 4, y: (2 * h.y + j.y + k.y) / 4 };
    // 几何点保持原值，阴影角度和纸背镜像都依赖它们；纸张快翻出时 H/J/K 会远离窗口，
    // 只在生成路径时再收回到窗口外的有限范围（见 pathPoint）。
    return {
      a: a,
      b: b,
      c: c,
      d: d,
      e: e,
      f: f,
      h: h,
      j: j,
      k: k,
      i: i,
      leftShadowDistance: this.pointToLineDistance(d, a, e),
      rightShadowDistance: this.pointToLineDistance(i, a, h),
      topCorner: topCorner,
      middleCorner: middleCorner
    };
  }

  private intersectionPoint(lineOneStart: FoldPoint, lineOneEnd: FoldPoint, lineTwoStart: FoldPoint,
    lineTwoEnd: FoldPoint): FoldPoint {
    const x1 = lineOneStart.x;
    const y1 = lineOneStart.y;
    const x2 = lineOneEnd.x;
    const y2 = lineOneEnd.y;
    const x3 = lineTwoStart.x;
    const y3 = lineTwoStart.y;
    const x4 = lineTwoEnd.x;
    const y4 = lineTwoEnd.y;
    const denominatorOne = (x3 - x4) * (y1 - y2) - (x1 - x2) * (y3 - y4);
    const denominatorTwo = (y1 - y2) * (x3 - x4) - (x1 - x2) * (y3 - y4);
    if (Math.abs(denominatorOne) < 0.0001 || Math.abs(denominatorTwo) < 0.0001) {
      return { x: lineOneStart.x, y: lineOneStart.y };
    }
    const x = ((x1 - x2) * (x3 * y4 - x4 * y3) - (x3 - x4) * (x1 * y2 - x2 * y1)) / denominatorOne;
    const y = ((y1 - y2) * (x3 * y4 - x4 * y3) - (x1 * y2 - x2 * y1) * (y3 - y4)) / denominatorTwo;
    return { x: x, y: y };
  }

  private pointToLineDistance(point: FoldPoint, lineStart: FoldPoint, lineEnd: FoldPoint): number {
    const a = lineStart.y - lineEnd.y;
    const b = lineEnd.x - lineStart.x;
    const c = lineStart.x * lineEnd.y - lineEnd.x * lineStart.y;
    const length = Math.hypot(a, b);
    if (length < 0.0001) {
      return 0;
    }
    return Math.abs((a * point.x + b * point.y + c) / length);
  }

  // 对应 checkDrawingAreaInWindow：折线完全移出窗口后停止绘制纸张。
  private isFoldOutOfWindow(geometry: FoldGeometry, height: number): boolean {
    const deltaX = geometry.d.x - geometry.i.x;
    if (Math.abs(deltaX) < 0.0001) {
      return true;
    }
    const slope = (geometry.d.y - geometry.i.y) / deltaX;
    const intercept = geometry.d.y - slope * geometry.d.x;
    if (geometry.topCorner && intercept > height) {
      return true;
    }
    return !geometry.topCorner && intercept < 0;
  }

  /**
   * 路径用的顶点：远离窗口的点沿它与 anchor 的连线收回到窗口外的有限范围。
   * 只钳制单个坐标会改变连线的斜率，纸张快翻出时会在窗口里留下一块错位的楔形。
   */
  private pathPoint(point: FoldPoint, anchor: FoldPoint, width: number, height: number): FoldPoint {
    const minX = -2 * width;
    const maxX = 3 * width;
    const minY = -2 * height;
    const maxY = 3 * height;
    if (point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY) {
      return point;
    }
    const dx = point.x - anchor.x;
    const dy = point.y - anchor.y;
    let scale = 1;
    if (dx > 0.0001) scale = Math.min(scale, (maxX - anchor.x) / dx);
    if (dx < -0.0001) scale = Math.min(scale, (minX - anchor.x) / dx);
    if (dy > 0.0001) scale = Math.min(scale, (maxY - anchor.y) / dy);
    if (dy < -0.0001) scale = Math.min(scale, (minY - anchor.y) / dy);
    scale = Math.max(0, scale);
    return { x: anchor.x + dx * scale, y: anchor.y + dy * scale };
  }

  private pathA(geometry: FoldGeometry, width: number, height: number): Path2D {
    const path = new Path2D();
    const a = geometry.a;
    const b = geometry.b;
    const c = geometry.c;
    const e = geometry.e;
    const k = this.pathPoint(geometry.k, a, width, height);
    const h = this.pathPoint(geometry.h, k, width, height);
    const j = this.pathPoint(geometry.j, k, width, height);
    if (geometry.topCorner) {
      // drawing.Path 在 reset() 后首个 lineTo 隐含从 (0,0) 起画，因此 pathA 是整页减去折角。
      path.moveTo(0, 0);
      path.lineTo(c.x, c.y);
      path.quadraticCurveTo(e.x, e.y, b.x, b.y);
      path.lineTo(a.x, a.y);
      path.lineTo(k.x, k.y);
      path.quadraticCurveTo(h.x, h.y, j.x, j.y);
      path.lineTo(width, height);
      path.lineTo(0, height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(0, height);
      path.lineTo(c.x, c.y);
      path.quadraticCurveTo(e.x, e.y, b.x, b.y);
      path.lineTo(a.x, a.y);
      path.lineTo(k.x, k.y);
      path.quadraticCurveTo(h.x, h.y, j.x, j.y);
      path.lineTo(width, 0);
    }
    path.closePath();
    return path;
  }

  private pathC(geometry: FoldGeometry, width: number, height: number): Path2D {
    const path = new Path2D();
    const a = geometry.a;
    const b = geometry.b;
    const d = geometry.d;
    const k = this.pathPoint(geometry.k, a, width, height);
    const i = this.pathPoint(geometry.i, d, width, height);
    path.moveTo(i.x, i.y);
    path.lineTo(d.x, d.y);
    path.lineTo(b.x, b.y);
    path.lineTo(a.x, a.y);
    path.lineTo(k.x, k.y);
    path.closePath();
    return path;
  }

  // 纸张翻起部分的两条实体纸边（原下边与原侧边），描一条细线把纸背和下层页面分开。
  private strokePaperEdge(context: CanvasRenderingContext2D, geometry: FoldGeometry, width: number,
    height: number): void {
    const a = geometry.a;
    const k = this.pathPoint(geometry.k, a, width, height);
    context.save();
    context.beginPath();
    context.moveTo(geometry.b.x, geometry.b.y);
    context.lineTo(a.x, a.y);
    context.lineTo(k.x, k.y);
    context.lineWidth = Math.max(0.5, this.vpPerPx);
    context.strokeStyle = this.paperEdgeColor;
    context.stroke();
    context.restore();
  }

  // 对应 drawPathC：纸张背面区域 + 反射内容 + 背页阴影。
  private drawPathC(context: CanvasRenderingContext2D, page: image.PixelMap, geometry: FoldGeometry,
    width: number, height: number): void {
    const path = this.pathC(geometry, width, height);
    context.save();
    context.fillStyle = this.activePaperColor;
    context.fill(path);

    const e = geometry.e;
    const f = geometry.f;
    const h = geometry.h;
    const foldLength = Math.hypot(f.x - e.x, h.y - f.y);
    if (foldLength > 0.0001) {
      const sin = (f.x - e.x) / foldLength;
      const cos = (h.y - f.y) / foldLength;
      context.save();
      context.clip(path);
      context.translate(e.x, e.y);
      context.transform(-(1 - 2 * sin * sin), 2 * sin * cos, 2 * sin * cos, 1 - 2 * sin * sin, 0, 0);
      context.translate(-e.x, -e.y);
      context.drawImage(page, 0, 0, width, height);
      context.restore();
    }

    context.fillStyle = this.backTintColor;
    context.fill(path);
    context.restore();

    context.save();
    context.clip(path);
    this.drawPathCShadow(context, geometry, width, height);
    context.restore();
    this.strokePaperEdge(context, geometry, width, height);
  }

  // 对应 drawPathCShadow。
  private drawPathCShadow(context: CanvasRenderingContext2D, geometry: FoldGeometry, width: number,
    height: number): void {
    const c = geometry.c;
    const e = geometry.e;
    const f = geometry.f;
    const h = geometry.h;
    const j = geometry.j;
    const top = c.y;
    const bottom = Math.hypot(width, height) + c.y;
    const midCE = (c.x + e.x) / 2;
    const midJH = (j.y + h.y) / 2;
    const controlDistance = Math.min(Math.abs(midCE - e.x), Math.abs(midJH - h.y));
    let left = 0;
    let right = 0;
    if (geometry.topCorner) {
      left = c.x - this.vpPerPx;
      right = c.x + controlDistance;
    } else {
      left = c.x - controlDistance;
      right = c.x + this.vpPerPx;
    }
    const rotateDegrees = this.rotationDegrees(h.y - f.y, e.x - f.x);
    const startX = geometry.topCorner ? right : left;
    const endX = geometry.topCorner ? left : right;
    this.paintRotatedShadow(context, null, left, top, right, bottom, rotateDegrees, c.x, c.y, endX, top, startX,
      top, [this.shadowLightColor, this.shadowBackDeepColor]);
  }

  // 对应 drawPathBShadow：折页投射到下一页上的阴影。
  private drawPathBShadow(context: CanvasRenderingContext2D, geometry: FoldGeometry, width: number,
    height: number): void {
    const a = geometry.a;
    const c = geometry.c;
    const e = geometry.e;
    const f = geometry.f;
    const h = geometry.h;
    const aToF = Math.hypot(a.x - f.x, a.y - f.y);
    const top = c.y;
    const bottom = Math.hypot(width, height) + c.y;
    // 官方取 aToF/4 作为投影带宽，纸张翻得越深带宽越大，看起来会和纸脱开。
    // 这里把带宽收窄并封顶，使阴影始终贴着折线。
    const bandWidth = Math.min(aToF / 4, width * 0.06);
    let left = 0;
    let right = 0;
    if (geometry.topCorner) {
      left = c.x;
      right = c.x + bandWidth;
    } else {
      left = c.x - bandWidth;
      right = c.x;
    }
    const rotateDegrees = this.rotationDegrees(h.y - f.y, e.x - f.x);
    const startX = geometry.topCorner ? right : left;
    const endX = geometry.topCorner ? left : right;
    this.paintRotatedShadow(context, null, left, top, right, bottom, rotateDegrees, c.x, c.y, endX, top, startX,
      top, [this.shadowDeepColor, this.shadowLightColor]);
  }

  // 对应 drawPathAContent：纸张正面剩余区域 + 页内阴影。
  private drawPathAContent(context: CanvasRenderingContext2D, page: image.PixelMap, geometry: FoldGeometry,
    width: number, height: number, mirrored: boolean): void {
    const path = this.pathA(geometry, width, height);
    context.save();
    context.clip(path);
    // 纸张正面始终按原方向绘制，保证正文不镜像。镜像变换自逆，再应用一次即可抵消。
    if (mirrored) {
      context.translate(width, 0);
      context.scale(-1, 1);
    }
    context.drawImage(page, 0, 0, width, height);
    context.restore();

    if (geometry.middleCorner) {
      this.drawPathAHorizontalShadow(context, geometry, path, width, height);
    } else {
      this.drawPathALeftShadow(context, geometry, path, width, height);
      this.drawPathARightShadow(context, geometry, path, width, height);
    }
  }

  // 对应 drawPathALeftShadow。
  private drawPathALeftShadow(context: CanvasRenderingContext2D, geometry: FoldGeometry, pathA: Path2D,
    width: number, height: number): void {
    const a = geometry.a;
    const d = geometry.d;
    const e = geometry.e;
    const top = e.y;
    const bottom = e.y + height;
    let left = 0;
    let right = 0;
    if (geometry.topCorner) {
      left = e.x - geometry.leftShadowDistance / 2;
      right = e.x;
    } else {
      left = e.x;
      right = e.x + geometry.leftShadowDistance / 2;
    }
    const rotateDegrees = this.rotationDegrees(a.y - e.y, e.x - a.x);
    const startX = geometry.topCorner ? right : left;
    const endX = geometry.topCorner ? left : right;
    const clip = new Path2D();
    const clipHalf = Math.max(geometry.rightShadowDistance, geometry.leftShadowDistance) / 2;
    clip.moveTo(a.x - clipHalf, a.y);
    clip.lineTo(d.x, d.y);
    clip.lineTo(e.x, e.y);
    clip.lineTo(a.x, a.y);
    clip.closePath();
    this.paintRotatedShadow(context, pathA, left, top, right, bottom, rotateDegrees, e.x, e.y, endX, top, startX,
      top, [this.shadowLightColor, this.shadowBackDeepColor], clip);
  }

  // 对应 drawPathARightShadow。
  private drawPathARightShadow(context: CanvasRenderingContext2D, geometry: FoldGeometry, pathA: Path2D,
    width: number, height: number): void {
    const a = geometry.a;
    const h = geometry.h;
    const diagonal = Math.hypot(width, height);
    const left = h.x;
    const right = h.x + diagonal * 10;
    let top = 0;
    let bottom = 0;
    if (geometry.topCorner) {
      top = h.y - geometry.rightShadowDistance / 2;
      bottom = h.y;
    } else {
      top = h.y;
      bottom = h.y + geometry.rightShadowDistance / 2;
    }
    const rotateDegrees = this.rotationDegrees(a.x - h.x, a.y - h.y);
    const startTop = geometry.topCorner ? top : bottom;
    const endTop = geometry.topCorner ? bottom : top;
    const clip = new Path2D();
    const clipHalf = Math.max(geometry.rightShadowDistance, geometry.leftShadowDistance) / 2;
    clip.moveTo(a.x - clipHalf, a.y);
    clip.lineTo(h.x, h.y);
    clip.lineTo(a.x, a.y);
    clip.closePath();
    this.paintRotatedShadow(context, pathA, left, top, right, bottom, rotateDegrees, h.x, h.y, left, endTop, left,
      startTop, [this.shadowDeepColor, this.shadowLightColor, this.shadowLightColor, this.shadowLightColor], clip);
  }

  // 对应 drawPathAHorizontalShadow。
  private drawPathAHorizontalShadow(context: CanvasRenderingContext2D, geometry: FoldGeometry, pathA: Path2D,
    width: number, height: number): void {
    const a = geometry.a;
    const left = a.x - Math.min(this.horizontalShadowMaxWidth * this.vpPerPx,
      geometry.rightShadowDistance / 2);
    const right = a.x + this.horizontalShadowRightExtend * this.vpPerPx;
    this.paintRotatedShadow(context, pathA, left, 0, right, height, 0, 0, 0, left, 0, right, 0,
      [this.shadowLightColor, this.shadowBackDeepColor]);
  }

  /**
   * 中部起手的竖折：折线竖直、随拖动从一侧扫到另一侧，折过去的半页以镜像形式盖在另一侧。
   * 官方 A–K 构造在竖折时会把折页退化成一条窄竖条，因此这里用显式的竖折几何。
   */
  private drawVerticalFold(context: CanvasRenderingContext2D, page: image.PixelMap, width: number, height: number,
    curl: number, direction: number): void {
    // 折线始终从页面一侧起步、随拖动 1:1 扫过整页，与起手位置无关。
    const creaseX = direction > 0 ? (1 - curl) * width : curl * width;
    // 1) 尚未折起的当前页部分（保持原样、正文正向）。
    const flatLeft = direction > 0 ? 0 : creaseX;
    const flatWidth = direction > 0 ? creaseX : width - creaseX;
    if (flatWidth > 0.5) {
      context.save();
      context.beginPath();
      context.rect(flatLeft, 0, flatWidth, height);
      context.clip();
      context.drawImage(page, 0, 0, width, height);
      context.restore();
    }
    // 2) 折过去的纸背：以折线为轴镜像。
    const flapLeft = Math.max(0, direction > 0 ? 2 * creaseX - width : creaseX);
    const flapRight = Math.min(width, direction > 0 ? creaseX : 2 * creaseX);
    const flapWidth = flapRight - flapLeft;
    if (flapWidth > 0.5) {
      context.save();
      context.beginPath();
      context.rect(flapLeft, 0, flapWidth, height);
      context.clip();
      context.fillStyle = this.activePaperColor;
      context.fillRect(flapLeft, 0, flapWidth, height);
      context.translate(2 * creaseX, 0);
      context.scale(-1, 1);
      context.drawImage(page, 0, 0, width, height);
      context.restore();

      context.save();
      context.beginPath();
      context.rect(flapLeft, 0, flapWidth, height);
      context.clip();
      context.fillStyle = this.backTintColor;
      context.fillRect(flapLeft, 0, flapWidth, height);
      context.restore();
    }
    // 纸张抬起的高度：两端贴着页面，翻到一半时最高，投影随之变宽。
    const lift = Math.sin(Math.PI * curl);
    if (flapWidth > 0.5) {
      // 3) 纸背的柱面明暗：靠近折线处背光最暗，中段迎光有一道高光，外侧纸边略微压暗。
      context.save();
      context.beginPath();
      context.rect(flapLeft, 0, flapWidth, height);
      context.clip();
      // 渐变按整张纸背的宽度铺开，纸边滑出窗口后只是被裁掉，明暗不会被挤压。
      const creaseSide = creaseX;
      const edgeSide = direction > 0 ? 2 * creaseX - width : 2 * creaseX;
      const shade = context.createLinearGradient(creaseSide, 0, edgeSide, 0);
      shade.addColorStop(0, this.shadowBackDeepColor);
      shade.addColorStop(0.22, this.shadowLightColor);
      shade.addColorStop(0.45, this.highlightClearColor);
      shade.addColorStop(0.62, this.highlightColor);
      shade.addColorStop(0.8, this.highlightClearColor);
      shade.addColorStop(0.82, this.shadowLightColor);
      shade.addColorStop(1, this.paperEdgeColor);
      context.fillStyle = shade;
      context.fillRect(flapLeft, 0, flapWidth, height);
      context.restore();

      // 4) 纸的外侧边落在当前页上的投影。纸边滑出窗口后不再需要。
      const edgeShadowWidth = Math.min(width * 0.07, 84) * lift;
      const edgeVisible = direction > 0 ? 2 * creaseX - width > 0 : 2 * creaseX < width;
      if (edgeVisible) {
        if (direction > 0) {
          this.fillHorizontalGradient(context, flapLeft - edgeShadowWidth, flapLeft, 0, height,
            this.shadowLightColor, this.edgeShadowColor);
        } else {
          this.fillHorizontalGradient(context, flapRight, flapRight + edgeShadowWidth, 0, height,
            this.edgeShadowColor, this.shadowLightColor);
        }
      }
    }
    // 5) 折线处落在目标页上的投影。
    const shadowWidth = Math.min(width * 0.10, 120) * (0.45 + 0.55 * lift);
    if (direction > 0) {
      this.fillHorizontalGradient(context, creaseX, creaseX + shadowWidth, 0, height,
        this.creaseShadowColor, this.shadowLightColor);
    } else {
      this.fillHorizontalGradient(context, creaseX - shadowWidth, creaseX, 0, height,
        this.shadowLightColor, this.creaseShadowColor);
    }
  }

  private rotationDegrees(deltaX: number, deltaY: number): number {
    if (Math.abs(deltaX) < 0.0001 && Math.abs(deltaY) < 0.0001) {
      return 0;
    }
    return Math.atan2(deltaY, deltaX) * 180 / Math.PI;
  }

  /**
   * 在可选裁剪区域内，围绕 (centerX, centerY) 旋转后填充一段线性渐变矩形。
   * gradientStart → gradientEnd 的用法与官方 createLinearGradient(endPt, startPt, colors) 对应。
   */
  private paintRotatedShadow(context: CanvasRenderingContext2D, clipPath: Path2D | null, left: number, top: number,
    right: number, bottom: number, rotateDegrees: number, centerX: number, centerY: number, gradientStartX: number,
    gradientStartY: number, gradientEndX: number, gradientEndY: number, colors: string[],
    intersectPath: Path2D | null = null): void {
    context.save();
    if (clipPath) {
      context.clip(clipPath);
    }
    if (intersectPath) {
      context.clip(intersectPath);
    }
    if (Math.abs(rotateDegrees) > 0.0001) {
      context.translate(centerX, centerY);
      context.rotate(rotateDegrees * Math.PI / 180);
      context.translate(-centerX, -centerY);
    }
    const gradient = context.createLinearGradient(gradientStartX, gradientStartY, gradientEndX, gradientEndY);
    for (let index = 0; index < colors.length; index++) {
      gradient.addColorStop(colors.length <= 1 ? 0 : index / (colors.length - 1), colors[index]);
    }
    context.fillStyle = gradient;
    context.fillRect(left, top, Math.max(1, right - left), Math.max(1, bottom - top));
    context.restore();
  }
}
