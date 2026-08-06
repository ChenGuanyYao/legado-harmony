import image from '@ohos.multimedia.image';

interface CurlPoint {
  x: number;
  y: number;
  face: number;
  shade: number;
}

interface CurlTriangle {
  sx0: number;
  sy0: number;
  sx1: number;
  sy1: number;
  sx2: number;
  sy2: number;
  d0: CurlPoint;
  d1: CurlPoint;
  d2: CurlPoint;
  face: number;
  shade: number;
}

/**
 * Paints a page as a mesh wrapped around a travelling cylinder. The model is deliberately
 * two-dimensional: it keeps the text snapshot sharp while reproducing the broad S-shaped
 * fold, visible paper back and moving cast shadow from the reference reader.
 */
export class ReaderPageCurlPainter {
  // The curl is almost linear on the vertical axis. A shallow vertical mesh keeps the S-shaped
  // fold while cutting clipped PixelMap draws substantially. A double-page leaf is only half as
  // wide, so eight columns retain roughly the same visual sampling density as a full-width leaf.
  private readonly singlePageMeshColumns: number = 14;
  private readonly doublePageMeshColumns: number = 8;
  private readonly meshRows: number = 2;
  // The fold radius is still about 0.115 leaf widths at the final frame. Travelling beyond
  // 1 + radius keeps the last folded strip fully outside the viewport instead of freezing
  // visibly while the reader commits the incoming page.
  private readonly pageTravelFactor: number = 1.14;

  draw(context: CanvasRenderingContext2D, front: image.PixelMap, back: image.PixelMap,
    canvasWidth: number, canvasHeight: number, progress: number, direction: number,
    doublePage: boolean, darkMode: boolean, topInset: number = 0): void {
    const width = Math.max(1, canvasWidth);
    const height = Math.max(1, canvasHeight);
    const leafWidth = doublePage ? width / 2 : width;
    const safeProgress = Math.max(0, Math.min(1, progress));
    const safeTopInset = Math.max(0, Math.min(height - 1, topInset));
    context.clearRect(0, 0, width, height);
    context.imageSmoothingEnabled = true;
    context.save();
    if (safeTopInset > 0) {
      // When body extension is disabled the status-bar wallpaper belongs to the stationary reader
      // background, not to the turning sheet. Keeping the curl out of this area also prevents the
      // snapshot texture from exposing an anti-aliased seam along the safe-area boundary.
      context.beginPath();
      context.moveTo(0, safeTopInset);
      context.lineTo(width, safeTopInset);
      context.lineTo(width, height);
      context.lineTo(0, height);
      context.closePath();
      context.clip();
    }
    if (safeProgress <= 0.001) {
      const startX = doublePage && direction > 0 ? leafWidth : 0;
      context.drawImage(front, startX, 0, leafWidth, height);
      context.restore();
      return;
    }

    this.drawCastShadow(context, width, height, leafWidth, safeProgress, direction, doublePage,
      darkMode);
    const triangles = this.buildTriangles(width, height, leafWidth, safeProgress, direction, doublePage);
    this.drawFace(context, triangles, front, leafWidth, height, 1, darkMode);
    this.drawFace(context, triangles, back, leafWidth, height, -1, darkMode);
    context.restore();
  }

  private buildTriangles(canvasWidth: number, canvasHeight: number, leafWidth: number,
    progress: number, direction: number, doublePage: boolean): CurlTriangle[] {
    const triangles: CurlTriangle[] = [];
    const points: CurlPoint[] = [];
    const meshColumns = doublePage ? this.doublePageMeshColumns : this.singlePageMeshColumns;
    const dx = leafWidth / meshColumns;
    const dy = canvasHeight / this.meshRows;
    for (let row = 0; row <= this.meshRows; row++) {
      const y = row * dy;
      for (let column = 0; column <= meshColumns; column++) {
        points.push(this.mapPoint(column * dx, y, canvasWidth, canvasHeight, leafWidth, progress,
          direction, doublePage));
      }
    }
    const rowLength = meshColumns + 1;
    for (let row = 0; row < this.meshRows; row++) {
      const y0 = row * dy;
      const y1 = (row + 1) * dy;
      for (let column = 0; column < meshColumns; column++) {
        const x0 = column * dx;
        const x1 = (column + 1) * dx;
        const topLeft = row * rowLength + column;
        const p00 = points[topLeft];
        const p10 = points[topLeft + 1];
        const p01 = points[topLeft + rowLength];
        const p11 = points[topLeft + rowLength + 1];
        triangles.push(this.makeTriangle(x0, y0, x1, y0, x1, y1, p00, p10, p11));
        triangles.push(this.makeTriangle(x0, y0, x1, y1, x0, y1, p00, p11, p01));
      }
    }
    return triangles;
  }

  private makeTriangle(sx0: number, sy0: number, sx1: number, sy1: number, sx2: number, sy2: number,
    d0: CurlPoint, d1: CurlPoint, d2: CurlPoint): CurlTriangle {
    const face = d0.face + d1.face + d2.face >= 0 ? 1 : -1;
    return {
      sx0: sx0,
      sy0: sy0,
      sx1: sx1,
      sy1: sy1,
      sx2: sx2,
      sy2: sy2,
      d0: d0,
      d1: d1,
      d2: d2,
      face: face,
      shade: (d0.shade + d1.shade + d2.shade) / 3
    };
  }

  private mapPoint(sourceX: number, sourceY: number, canvasWidth: number, canvasHeight: number,
    leafWidth: number, progress: number, direction: number, doublePage: boolean): CurlPoint {
    const canonicalX = direction > 0 ? sourceX : leafWidth - sourceX;
    const axisTilt = -0.14 * Math.sin(progress * Math.PI);
    const cosine = Math.cos(axisTilt);
    const sine = Math.sin(axisTilt);
    const centerY = canvasHeight * 0.64;
    const tangentY = sourceY - centerY;
    const normal = canonicalX * cosine - tangentY * sine;
    const tangent = canonicalX * sine + tangentY * cosine;
    const axis = leafWidth * (1 - progress * this.pageTravelFactor);
    const radius = leafWidth * (0.115 + 0.065 * Math.sin(progress * Math.PI));
    const distance = normal - axis;
    let mappedNormal = normal;
    let face = 1;
    let shade = 0;
    if (distance > 0) {
      const angle = distance / Math.max(1, radius);
      if (angle < Math.PI) {
        mappedNormal = axis + radius * Math.sin(angle);
        face = Math.cos(angle) >= 0 ? 1 : -1;
        shade = Math.min(1, Math.abs(Math.sin(angle)) * 0.82 + (face < 0 ? 0.18 : 0));
      } else {
        mappedNormal = axis - (distance - Math.PI * radius);
        face = -1;
        shade = Math.max(0.16, 0.46 - Math.min(0.3, (angle - Math.PI) * 0.07));
      }
    }
    const mappedX = mappedNormal * cosine + tangent * sine;
    const curledY = centerY - mappedNormal * sine + tangent * cosine;
    // Keep the physical top and bottom edges attached to the viewport. Applying the full tilted-axis displacement
    // at y=0/height lifts the sheet away from the screen edge and reads as vertical compression. The middle of the
    // leaf retains the S-shaped curl, while the displacement fades smoothly to zero at both horizontal edges.
    const edgeLock = Math.sin(Math.PI * Math.max(0, Math.min(1, sourceY / Math.max(1, canvasHeight))));
    const mappedY = sourceY + (curledY - sourceY) * edgeLock;
    const canonicalOrigin = doublePage ? leafWidth : 0;
    const canonicalGlobalX = canonicalOrigin + mappedX;
    return {
      x: direction > 0 ? canonicalGlobalX : canvasWidth - canonicalGlobalX,
      y: mappedY,
      face: face,
      shade: shade
    };
  }

  private drawFace(context: CanvasRenderingContext2D, triangles: CurlTriangle[], texture: image.PixelMap,
    leafWidth: number, leafHeight: number, face: number, darkMode: boolean): void {
    for (const triangle of triangles) {
      if (triangle.face !== face) continue;
      this.drawTexturedTriangle(context, triangle, texture, leafWidth, leafHeight,
        face < 0 ? 0.83 : 1);
      const alpha = face < 0 ? 0.13 + triangle.shade * 0.26 : triangle.shade * 0.12;
      if (alpha > 0.01) {
        this.fillTriangle(context, triangle, darkMode ? '#05080B' : (face < 0 ? '#D8D2C6' : '#5D554A'),
          alpha);
      }
    }
  }

  private drawTexturedTriangle(context: CanvasRenderingContext2D, triangle: CurlTriangle,
    texture: image.PixelMap, leafWidth: number, leafHeight: number, alpha: number): void {
    const sx1 = triangle.sx1 - triangle.sx0;
    const sy1 = triangle.sy1 - triangle.sy0;
    const sx2 = triangle.sx2 - triangle.sx0;
    const sy2 = triangle.sy2 - triangle.sy0;
    const determinant = sx1 * sy2 - sx2 * sy1;
    if (Math.abs(determinant) < 0.0001) return;
    const dx1 = triangle.d1.x - triangle.d0.x;
    const dy1 = triangle.d1.y - triangle.d0.y;
    const dx2 = triangle.d2.x - triangle.d0.x;
    const dy2 = triangle.d2.y - triangle.d0.y;
    const a = (dx1 * sy2 - dx2 * sy1) / determinant;
    const b = (dy1 * sy2 - dy2 * sy1) / determinant;
    const c = (-dx1 * sx2 + dx2 * sx1) / determinant;
    const d = (-dy1 * sx2 + dy2 * sx1) / determinant;
    const e = triangle.d0.x - a * triangle.sx0 - c * triangle.sy0;
    const f = triangle.d0.y - b * triangle.sx0 - d * triangle.sy0;
    context.save();
    this.trianglePath(context, triangle);
    context.clip();
    context.transform(a, b, c, d, e, f);
    context.globalAlpha = alpha;
    context.drawImage(texture, 0, 0, leafWidth, leafHeight);
    context.restore();
  }

  private fillTriangle(context: CanvasRenderingContext2D, triangle: CurlTriangle, color: string,
    alpha: number): void {
    context.save();
    this.trianglePath(context, triangle);
    context.globalAlpha = Math.max(0, Math.min(1, alpha));
    context.fillStyle = color;
    context.fill();
    context.restore();
  }

  private trianglePath(context: CanvasRenderingContext2D, triangle: CurlTriangle): void {
    const centerX = (triangle.d0.x + triangle.d1.x + triangle.d2.x) / 3;
    const centerY = (triangle.d0.y + triangle.d1.y + triangle.d2.y) / 3;
    context.beginPath();
    this.moveToExpandedPoint(context, triangle.d0, centerX, centerY, true);
    this.moveToExpandedPoint(context, triangle.d1, centerX, centerY, false);
    this.moveToExpandedPoint(context, triangle.d2, centerX, centerY, false);
    context.closePath();
  }

  private moveToExpandedPoint(context: CanvasRenderingContext2D, point: CurlPoint,
    centerX: number, centerY: number, move: boolean): void {
    const dx = point.x - centerX;
    const dy = point.y - centerY;
    const length = Math.max(0.01, Math.sqrt(dx * dx + dy * dy));
    const overlap = 0.72;
    const x = point.x + dx / length * overlap;
    const y = point.y + dy / length * overlap;
    if (move) context.moveTo(x, y);
    else context.lineTo(x, y);
  }

  private drawCastShadow(context: CanvasRenderingContext2D, canvasWidth: number, canvasHeight: number,
    leafWidth: number, progress: number, direction: number, doublePage: boolean, darkMode: boolean): void {
    const shadowWidth = leafWidth * (0.12 + 0.11 * Math.sin(progress * Math.PI));
    const edge: CurlPoint[] = [];
    for (let index = 0; index <= 10; index++) {
      const y = canvasHeight * index / 10;
      const sourceX = leafWidth * Math.min(1, Math.max(0, 1 - progress * this.pageTravelFactor +
        (0.5 * Math.PI) * (0.115 + 0.065 * Math.sin(progress * Math.PI))));
      edge.push(this.mapPoint(direction > 0 ? sourceX : leafWidth - sourceX, y, canvasWidth, canvasHeight,
        leafWidth, progress, direction, doublePage));
    }
    context.save();
    context.beginPath();
    context.moveTo(edge[0].x, edge[0].y);
    for (let index = 1; index < edge.length; index++) context.lineTo(edge[index].x, edge[index].y);
    for (let index = edge.length - 1; index >= 0; index--) {
      context.lineTo(edge[index].x + (direction > 0 ? shadowWidth : -shadowWidth), edge[index].y);
    }
    context.closePath();
    let minX = edge[0].x;
    let maxX = edge[0].x;
    for (const point of edge) {
      minX = Math.min(minX, point.x);
      maxX = Math.max(maxX, point.x);
    }
    const gradient = direction > 0 ?
      context.createLinearGradient(minX, 0, maxX + shadowWidth, 0) :
      context.createLinearGradient(minX - shadowWidth, 0, maxX, 0);
    if (direction > 0) {
      gradient.addColorStop(0, darkMode ? '#99000000' : '#72000000');
      gradient.addColorStop(1, '#00000000');
    } else {
      gradient.addColorStop(0, '#00000000');
      gradient.addColorStop(1, darkMode ? '#99000000' : '#72000000');
    }
    // Fade the cast shadow with the departing edge. A non-zero shadow on the final frame made
    // the completed page look stationary until the declarative surface handoff finished.
    const finishFade = Math.max(0, Math.min(1, (1 - progress) / 0.12));
    context.globalAlpha = (0.25 + 0.42 * Math.sin(progress * Math.PI)) * finishFade;
    context.fillStyle = gradient;
    context.fill();
    context.restore();
  }
}
