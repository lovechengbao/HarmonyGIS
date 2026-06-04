/**
 * HttpResumeDownloader — 基于文件尺寸的断点续传下载器
 *
 * 与 DownloadTask 的区别：
 * - DownloadTask 在内存中跟踪已下载字节数并通过 persist 层持久化
 * - 本类直接从磁盘文件尺寸推断断点位置，无需额外持久化
 * - 更轻量，适合简单的单文件下载场景
 *
 * 使用示例：
 * ```typescript
 * const downloader = new HttpResumeDownloader(
 *   'https://example.com/map.mbtiles',
 *   context.filesDir + '/maps/beijing.mbtiles'
 * );
 *
 * downloader.onProgress((downloaded, total, speed) => {
 *   console.log(`${downloaded}/${total} @ ${speed} B/s`);
 * });
 * downloader.onComplete((path) => {
 *   console.log('下载完成:', path);
 * });
 *
 * await downloader.start();
 *
 * // 暂停
 * downloader.pause();
 *
 * // 恢复（自动带上 Range: bytes={文件尺寸}-）
 * await downloader.start();
 * ```
 *
 * 适配 HarmonyOS API 11：
 * - 网络：@ohos.net.http（流式 dataReceive/dataEnd/dataError 事件）
 * - 文件：@ohos.file.fs（open/write/close）
 */

import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 进度回调 */
export interface ResumeProgressCallback {
  (downloaded: number, total: number, speed: number): void;
}

/** 完成回调 */
export interface ResumeCompleteCallback {
  (filePath: string): void;
}

/** 错误回调 */
export interface ResumeErrorCallback {
  (error: string): void;
}

/** 下载器状态 */
export enum ResumeDownloaderState {
  /** 空闲（未开始或已完成） */
  IDLE = 'idle',
  /** 下载中 */
  DOWNLOADING = 'downloading',
  /** 已暂停 */
  PAUSED = 'paused',
  /** 已完成 */
  COMPLETED = 'completed',
  /** 失败 */
  FAILED = 'failed',
  /** 已取消 */
  CANCELLED = 'cancelled'
}

export class HttpResumeDownloader {
  /** 下载地址 */
  private url: string;
  /** 完整保存路径 */
  private filePath: string;
  /** 超时时间 (ms) */
  private connectTimeout: number;
  private readTimeout: number;
  /** 自定义请求头 */
  private customHeaders: Record<string, string>;

  // ── 运行时状态 ──
  private httpRequest: http.HttpRequest | null = null;
  private fileFd: number = -1;
  private state: ResumeDownloaderState = ResumeDownloaderState.IDLE;
  private startByte: number = 0;
  private downloadedBytes: number = 0;
  private totalBytes: number = -1;

  // ── 速度跟踪 ──
  private lastSpeedTime: number = 0;
  private lastSpeedBytes: number = 0;
  private currentSpeed: number = 0;

  // ── 回调 ──
  private progressCallback: ResumeProgressCallback | null = null;
  private completeCallback: ResumeCompleteCallback | null = null;
  private errorCallback: ResumeErrorCallback | null = null;

  // ── 控制标志 ──
  private shouldStop: boolean = false;

  /**
   * @param url 下载地址
   * @param filePath 完整保存路径（如 context.filesDir + '/maps/tile.mbtiles'）
   * @param options 可选配置
   */
  constructor(
    url: string,
    filePath: string,
    options?: {
      connectTimeout?: number;
      readTimeout?: number;
      headers?: Record<string, string>;
    }
  ) {
    this.url = url;
    this.filePath = filePath;
    this.connectTimeout = options?.connectTimeout ?? 60000;
    this.readTimeout = options?.readTimeout ?? 60000;
    this.customHeaders = options?.headers ?? {};
  }

  // ═══════════════════════════════════════════════════════════
  // 公开 API
  // ═══════════════════════════════════════════════════════════

  /**
   * 注册进度回调
   *
   * @param callback (downloadedBytes, totalBytes, speedBytesPerSecond)
   */
  onProgress(callback: ResumeProgressCallback): void {
    this.progressCallback = callback;
  }

  /**
   * 注册完成回调
   */
  onComplete(callback: ResumeCompleteCallback): void {
    this.completeCallback = callback;
  }

  /**
   * 注册错误回调
   */
  onError(callback: ResumeErrorCallback): void {
    this.errorCallback = callback;
  }

  /**
   * 获取当前状态
   */
  getState(): ResumeDownloaderState {
    return this.state;
  }

  /**
   * 获取进度快照
   */
  getProgress(): { downloaded: number; total: number; speed: number } {
    return {
      downloaded: this.downloadedBytes,
      total: this.totalBytes,
      speed: this.currentSpeed
    };
  }

  /**
   * 启动下载（自动检测断点）
   *
   * - 首次调用：检查本地文件尺寸，若存在则从断点续传
   * - 暂停后调用：从已下载位置继续（带 Range 头）
   */
  async start(): Promise<void> {
    if (this.state === ResumeDownloaderState.DOWNLOADING) {
      console.warn('[HttpResumeDownloader] 已在下载中');
      return;
    }

    if (this.state === ResumeDownloaderState.COMPLETED) {
      console.info('[HttpResumeDownloader] 已下载完成，跳过');
      return;
    }

    this.shouldStop = false;

    // 检测本地文件尺寸以确定断点位置
    if (this.state === ResumeDownloaderState.IDLE) {
      this.startByte = this.checkFileSize();
    }
    // PAUSED 状态下 startByte 保持不变（已在 downloadLoop 中更新）

    this.downloadedBytes = this.startByte;

    try {
      this.setState(ResumeDownloaderState.DOWNLOADING);
      await this.downloadLoop();
    } catch (err) {
      if (this.shouldStop) {
        return; // pause/cancel 触发的中断，不视为错误
      }
      const errMsg = `下载失败: ${JSON.stringify(err)}`;
      console.error(`[HttpResumeDownloader] ${errMsg}`);
      this.setState(ResumeDownloaderState.FAILED);
      this.errorCallback?.(errMsg);
    }
  }

  /**
   * 暂停下载 — 关闭 HTTP 连接，保留已下载文件
   */
  pause(): void {
    if (this.state !== ResumeDownloaderState.DOWNLOADING) {
      return;
    }
    this.shouldStop = true;
    this.destroyHttpRequest();
    this.closeFileFd();
    this.startByte = this.downloadedBytes; // 更新断点位置供下次 start() 使用
    this.setState(ResumeDownloaderState.PAUSED);
    console.info(`[HttpResumeDownloader] 已暂停, nextStartByte=${this.startByte}`);
  }

  /**
   * 取消下载
   *
   * @param deleteFile 是否同时删除已下载的部分文件
   */
  async cancel(deleteFile: boolean = false): Promise<void> {
    this.shouldStop = true;
    this.destroyHttpRequest();
    this.closeFileFd();

    if (deleteFile) {
      try {
        fs.unlinkSync(this.filePath);
        console.info(`[HttpResumeDownloader] 已删除文件: ${this.filePath}`);
      } catch (_e) {
        // 文件可能不存在
      }
    }

    this.setState(ResumeDownloaderState.CANCELLED);
    this.startByte = 0;
    this.downloadedBytes = 0;
  }

  /**
   * 重置下载器状态（不清除本地文件）
   */
  reset(): void {
    this.destroyHttpRequest();
    this.closeFileFd();
    this.state = ResumeDownloaderState.IDLE;
    this.startByte = 0;
    this.downloadedBytes = 0;
    this.totalBytes = -1;
    this.currentSpeed = 0;
    this.shouldStop = false;
  }

  // ═══════════════════════════════════════════════════════════
  // 下载核心
  // ═══════════════════════════════════════════════════════════

  /**
   * 发起带 Range 头的流式下载
   */
  private async downloadLoop(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      // 清理旧连接
      this.destroyHttpRequest();
      this.closeFileFd();

      // 打开文件（新下载截断，续传追加）
      this.openFile();

      // 构建请求头
      const headers: Record<string, string> = {};
      const customKeys = Object.keys(this.customHeaders);
      for (let i = 0; i < customKeys.length; i++) {
        headers[customKeys[i]] = this.customHeaders[customKeys[i]];
      }

      if (this.startByte > 0) {
        headers['Range'] = `bytes=${this.startByte}-`;
        console.info(`[HttpResumeDownloader] 断点续传 Range: bytes=${this.startByte}-`);
      }

      // 创建 HTTP 请求
      this.httpRequest = http.createHttp();

      // ── dataReceive: 逐块写入文件 ──
      this.httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        if (this.shouldStop) {
          return;
        }
        try {
          fs.writeSync(this.fileFd, data);
          const chunkSize = data.byteLength;
          this.downloadedBytes += chunkSize;
          this.updateSpeed(chunkSize);
          this.notifyProgress();
        } catch (err) {
          console.error(`[HttpResumeDownloader] 写文件失败: ${JSON.stringify(err)}`);
          reject(new Error(`写文件失败: ${JSON.stringify(err)}`));
        }
      });

      // ── dataProgress: 获取总大小 ──
      this.httpRequest.on('dataProgress',
        (progress: { receiveSize: number; totalSize: number }) => {
        if (progress.totalSize > 0) {
          // Content-Length 语义：
          //   startByte=0 → Content-Length 是完整文件大小
          //   startByte>0 → Content-Length 是剩余字节数
          this.totalBytes = this.startByte + progress.totalSize;
        }
      });

      // ── dataEnd: 下载完成 ──
      this.httpRequest.on('dataEnd', () => {
        if (this.shouldStop) {
          resolve();
          return;
        }
        this.closeFileFd();
        this.setState(ResumeDownloaderState.COMPLETED);
        console.info(`[HttpResumeDownloader] 下载完成: ${this.filePath}`);
        this.completeCallback?.(this.filePath);
        resolve();
      });

      // ── dataError: 下载出错 ──
      this.httpRequest.on('dataError', (err: Error) => {
        if (this.shouldStop) {
          resolve();
          return;
        }
        this.closeFileFd();
        reject(err);
      });

      // ── 发起请求 ──
      this.httpRequest.request(this.url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: this.connectTimeout,
        readTimeout: this.readTimeout,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      }).catch((err: Error) => {
        if (this.shouldStop) {
          resolve();
          return;
        }
        this.closeFileFd();
        reject(err);
      });
    });
  }

  // ═══════════════════════════════════════════════════════════
  // 文件操作
  // ═══════════════════════════════════════════════════════════

  /**
   * 检查本地文件尺寸，返回断点位置
   */
  private checkFileSize(): number {
    try {
      const stat = fs.statSync(this.filePath);
      if (stat.size > 0) {
        console.info(`[HttpResumeDownloader] 检测到已有文件, size=${stat.size}`);
        return stat.size;
      }
    } catch (_e) {
      // 文件不存在，从头开始
    }
    return 0;
  }

  /**
   * 打开文件（新下载截断创建，续传追加写）
   */
  private openFile(): void {
    try {
      if (this.startByte > 0) {
        // 断点续传：追加模式，不截断已有数据
        this.fileFd = fs.openSync(
          this.filePath,
          fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND | fs.OpenMode.CREATE
        );
      } else {
        // 新下载：截断创建
        this.fileFd = fs.openSync(
          this.filePath,
          fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
        );
      }
      console.info(`[HttpResumeDownloader] 文件已打开, append=${this.startByte > 0}`);
    } catch (err) {
      console.error(`[HttpResumeDownloader] 打开文件失败: ${JSON.stringify(err)}`);
      throw err;
    }
  }

  /**
   * 安全关闭文件描述符
   */
  private closeFileFd(): void {
    if (this.fileFd >= 0) {
      try {
        fs.closeSync(this.fileFd);
      } catch (err) {
        console.warn(`[HttpResumeDownloader] 关闭文件异常: ${JSON.stringify(err)}`);
      }
      this.fileFd = -1;
    }
  }

  /**
   * 销毁 HTTP 请求
   */
  private destroyHttpRequest(): void {
    if (this.httpRequest) {
      try {
        this.httpRequest.off('dataReceive');
        this.httpRequest.off('dataProgress');
        this.httpRequest.off('dataEnd');
        this.httpRequest.off('dataError');
        this.httpRequest.destroy();
      } catch (err) {
        console.warn(`[HttpResumeDownloader] 销毁 HTTP 请求异常: ${JSON.stringify(err)}`);
      }
      this.httpRequest = null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 进度 & 速度
  // ═══════════════════════════════════════════════════════════

  /**
   * 更新速度统计
   */
  private updateSpeed(chunkSize: number): void {
    const now = Date.now();
    const delta = now - this.lastSpeedTime;

    if (delta >= 1000) {
      const bytesDelta = this.downloadedBytes - this.lastSpeedBytes;
      this.currentSpeed = delta > 0 ?
        Math.round((bytesDelta / delta) * 1000) :
        0;
      this.lastSpeedTime = now;
      this.lastSpeedBytes = this.downloadedBytes;
    }
  }

  /**
   * 通知进度回调
   */
  private notifyProgress(): void {
    this.progressCallback?.(this.downloadedBytes, this.totalBytes, this.currentSpeed);
  }

  // ═══════════════════════════════════════════════════════════
  // 状态管理
  // ═══════════════════════════════════════════════════════════

  /**
   * 更新状态
   */
  private setState(newState: ResumeDownloaderState): void {
    const oldState = this.state;
    this.state = newState;
    if (oldState !== newState) {
      console.info(`[HttpResumeDownloader] 状态: ${oldState} → ${newState}`);
    }
  }
}
