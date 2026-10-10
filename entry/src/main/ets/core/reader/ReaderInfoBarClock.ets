import { batteryInfo } from '@kit.BasicServicesKit';

/**
 * 页眉页脚里时间与电量的刷新时钟：启动时立即回调一次，之后对齐到每分钟整点回调。
 * 电量变化很慢，跟着分钟节拍一起读取即可，不单独订阅系统事件。
 */
export class ReaderInfoBarClock {
  private timerId: number = -1;
  private onTick: () => void;

  constructor(onTick: () => void) {
    this.onTick = onTick;
  }

  start(): void {
    if (this.timerId >= 0) return;
    this.onTick();
    this.schedule();
  }

  stop(): void {
    if (this.timerId < 0) return;
    clearTimeout(this.timerId);
    this.timerId = -1;
  }

  private schedule(): void {
    // 多等 50ms，确保回调时系统时间已经进入下一分钟。
    const delay = 60000 - (Date.now() % 60000) + 50;
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      this.onTick();
      this.schedule();
    }, delay);
  }

  static timeText(): string {
    const now = new Date();
    const hours = now.getHours();
    const minutes = now.getMinutes();
    return `${hours < 10 ? '0' : ''}${hours}:${minutes < 10 ? '0' : ''}${minutes}`;
  }

  /** 当前电量百分比；读取失败返回 -1。 */
  static batteryPercent(): number {
    try {
      const value = batteryInfo.batterySOC;
      return typeof value === 'number' && value >= 0 ? value : -1;
    } catch (_) {
      return -1;
    }
  }
}
