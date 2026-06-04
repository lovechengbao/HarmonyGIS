/**
 * DownloadTask — 单个下载任务封装（基于 @ohos.net.http）
 *
 * 使用 HTTP 直连替代 request.agent，实现真正的 HTTP Range 断点续传。
 *
 * 关键改进：
 * - resume 时显式设置 Range: bytes={downloaded}- 请求头
 * - 流式写入文件（dataReceive 逐块落盘，避免占用大量内存）
 * - 暂停时立即关闭 HTTP 连接和文件描述符
 * - 失败自动重试（带递增延迟）
 *
 * request.agent 的 begins 参数在 HarmonyOS 中不会生成 Range 头，
 * 因此改用 http 模块完全自主控制 HTTP 行为。
 */

import { http } from '@ohos.net.http';
import { fileIo } from '@ohos.file.fs';
import {
  DownloadCallbacks,
  DownloadConfig,
  DownloadProgress,
  DownloadState,
  HttpProgressData
} from './DownloadTypes';
import { saveTaskInfo, removeTaskInfo, updateTaskState } from './DownloadPersist';

/** 进度持久化间隔 (ms) */
const PERSIST_INTERVAL = 5000;
/** 默认最大重试次数 */
const DEFAULT_MAX_RETRIES = 3;
/** 默认重试间隔 (ms) */
const DEFAULT_RETRY_DELAY = 5000;

export class DownloadTask {
  /** 任务唯一标识（应用层生成并持久化） */
  private tid: string = '';
  /** HTTP 请求实例（下载中非空，暂停/完成后为 null） */
  private httpRequest: http.HttpRequest | null = null;
  /** 当前打开的文件对象（null 表示未打开） */
  private file: fileIo.File | null = null;
  /** 异步写队列：保证写入顺序，避免多个 write 并发导致数据错乱 */
  private writeQueue: Promise<void> = Promise.resolve();
  /** 任务配置 */
  private config: DownloadConfig;
  /** 回调集合 */
  private callbacks: DownloadCallbacks;
  /** 当前状态 */
  private state: DownloadState = DownloadState.PENDING;
  /** 完整保存路径 */
  private filePath: string = '';
  /** filesDir（持久化用） */
  private filesDir: string;

  // ── 进度跟踪 ──
  private downloadedBytes: number = 0;
  private totalBytes: number = -1;
  private lastPersistTime: number = 0;

  // ── 重试 ──
  private retryCount: number = 0;
  private maxRetries: number;
  private retryDelay: number;
  private retryTimer: number | null = null;

  /** 是否已销毁 */
  private destroyed: boolean = false;

  constructor(config: DownloadConfig, callbacks: DownloadCallbacks, filesDir: string) {
    this.config = config;
    this.callbacks = callbacks;
    this.maxRetries = config.maxRetries ?? DEFAULT_MAX_RETRIES;
    this.retryDelay = config.retryDelay ?? DEFAULT_RETRY_DELAY;
    this.filePath = config.saveDir + '/' + config.fileName;
    this.filesDir = filesDir;
  }

  /**
   * 获取任务唯一标识
   */
  getTaskId(): string {
    return this.tid;
  }

  /**
   * 获取当前状态
   */
  getState(): DownloadState {
    return this.state;
  }

  /**
   * 获取当前进度快照
   */
  getProgress(): DownloadProgress {
    let progress = 0;
    if (this.totalBytes > 0) {
      progress = Math.round((this.downloadedBytes / this.totalBytes) * 100);
    }
    return {
      taskId: this.tid,
      state: this.state,
      downloadedBytes: this.downloadedBytes,
      totalBytes: this.totalBytes,
      progress: progress,
      updateTime: Date.now()
    };
  }

  /**
   * 获取文件保存路径
   */
  getFilePath(): string {
    return this.filePath;
  }

  /**
   * 创建并启动下载任务（新任务，begins=0）
   */
  async start(): Promise<void> {
    if (this.destroyed) {
      return;
    }

    try {
      this.tid = this.generateTaskId();
      await this.startHttpDownload(0);
      this.setState(DownloadState.DOWNLOADING);
      const now = Date.now();
      this.lastPersistTime = now;

      // 持久化任务信息
      await this.persistTaskInfo();
      console.info(`[DownloadTask] 下载启动成功, taskId: ${this.tid}`);
    } catch (err) {
      const msg = `启动下载失败: ${JSON.stringify(err)}`;
      console.error(`[DownloadTask] ${msg}`);
      await this.handleFailure(msg);
    }
  }

  /**
   * 暂停下载 — 关闭 HTTP 连接和文件描述符
   */
  async pause(): Promise<void> {
    if (this.state !== DownloadState.DOWNLOADING) {
      return;
    }

    this.destroyHttpRequest();
    await this.closeFile();
    this.setState(DownloadState.PAUSED);
    await updateTaskState(this.filesDir, this.tid, DownloadState.PAUSED, this.downloadedBytes,
      this.totalBytes);
    this.callbacks.onPaused?.(this.tid);
    console.info(`[DownloadTask] 已暂停, taskId: ${this.tid}, 已下载: ${this.downloadedBytes}`);
  }

  /**
   * 恢复下载（断点续传）
   *
   * 发送 HTTP Range: bytes={downloaded}- 请求头，从已下载位置继续。
   */
  async resume(): Promise<void> {
    if (this.state !== DownloadState.PAUSED) {
      return;
    }

    try {
      await this.startHttpDownload(this.downloadedBytes);
      this.setState(DownloadState.DOWNLOADING);
      const now = Date.now();
      this.lastPersistTime = now;
      this.retryCount = 0;
      await this.persistTaskInfo();
      console.info(`[DownloadTask] 已恢复下载（Range: bytes=${this.downloadedBytes}-）, taskId: ${this.tid}`);
    } catch (err) {
      const msg = `恢复下载失败: ${JSON.stringify(err)}`;
      console.error(`[DownloadTask] ${msg}`);
      await this.handleFailure(msg);
    }
  }

  /**
   * 取消并删除任务 — 关闭 HTTP 连接、关闭文件、清理持久化
   */
  async cancel(): Promise<void> {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.clearRetryTimer();

    this.destroyHttpRequest();
    await this.closeFile();

    this.setState(DownloadState.CANCELLED);
    await removeTaskInfo(this.filesDir, this.tid);
    console.info(`[DownloadTask] 已取消, taskId: ${this.tid}`);
  }

  /**
   * 从持久化数据恢复任务（应用重启后调用）
   *
   * 由于 HTTP 连接无法跨进程存活，重启后任务自动进入 PAUSED 状态，
   * 下次 resume() 时会带上 Range 头从断点继续。
   */
  recover(taskId: string, downloadedBytes: number, totalBytes: number): void {
    this.tid = taskId;
    this.downloadedBytes = downloadedBytes;
    this.totalBytes = totalBytes;
    this.setState(DownloadState.PAUSED);
    console.info(`[DownloadTask] 恢复任务: ${taskId}, 已下载: ${downloadedBytes}/${totalBytes}`);
  }

  /**
   * 更新回调（用于恢复任务后重新绑定回调）
   */
  setCallbacks(callbacks: DownloadCallbacks): void {
    this.callbacks = callbacks;
  }

  /**
   * 销毁（暂停任务，但不删除持久化记录）
   *
   * 用于 App 退出前批量暂停所有活跃任务。
   */
  async destroy(): Promise<void> {
    this.destroyed = true;
    this.clearRetryTimer();

    if (this.state === DownloadState.DOWNLOADING) {
      this.destroyHttpRequest();
      await this.closeFile();
      this.setState(DownloadState.PAUSED);
      await updateTaskState(this.filesDir, this.tid, DownloadState.PAUSED, this.downloadedBytes,
        this.totalBytes);
      console.info(`[DownloadTask] 销毁时已暂停任务, tid: ${this.tid}`);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // HTTP 下载核心
  // ═══════════════════════════════════════════════════════════

  /**
   * 启动 HTTP 流式下载
   *
   * @param begins 起始字节偏移（0 = 新下载，>0 = 断点续传）
   */
  private async startHttpDownload(begins: number): Promise<void> {
    // 清理旧资源（异步，不阻塞主线程）
    this.destroyHttpRequest();
    await this.closeFile();
    await this.openFile(begins > 0);

    // 构建请求头：断点续传时添加 Range
    const headers: Record<string, string> = {};
    if (this.config.headers) {
      const keys = Object.keys(this.config.headers);
      for (let i = 0; i < keys.length; i++) {
        headers[keys[i]] = this.config.headers[keys[i]];
      }
    }

    if (begins > 0) {
      headers['Range'] = `bytes=${begins}-`;
      console.info(`[DownloadTask] Range 请求头: bytes=${begins}-`);
    }

    return new Promise<void>((resolve, reject) => {
      // 创建 HTTP 请求
      this.httpRequest = http.createHttp();

      // ── dataReceive: 异步顺序写入文件，不阻塞主线程 ──
      this.httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        if (this.destroyed || !this.file) {
          return;
        }
        // 用写队列保证写入顺序（后一块必须等前一块写完）
        this.writeQueue = this.writeQueue.then(async () => {
          await fileIo.write(this.file!.fd, data);
          this.downloadedBytes += data.byteLength;
          await this.updateProgressCallback();
        }).catch((err: Error) => {
          console.error(`[DownloadTask] 写文件失败: ${err.message}`);
          reject(new Error(`写文件失败: ${err.message}`));
        });
      });

      // ── dataReceiveProgress: 获取总大小（API 11 事件名）──
      this.httpRequest.on('dataReceiveProgress',
        (progress: HttpProgressData) => {
        if (progress.totalSize > 0) {
          // Content-Length 语义：
          // - 新下载 (begins=0): Content-Length = 完整文件大小
          // - 断点续传 (begins>0): Content-Length = 剩余字节数
          this.totalBytes = begins > 0 ?
            begins + progress.totalSize :
            progress.totalSize;
        }
      });

      // ── dataEnd: 下载完成 ──
      this.httpRequest.on('dataEnd', async () => {
        if (this.destroyed) {
          return;
        }
        // 等待所有排队的写操作完成
        await this.writeQueue;
        await this.closeFile();
        await this.handleCompleted();
        resolve();
      });

      // ── 发起流式请求（API 11: requestInStream）──
      this.httpRequest.requestInStream(this.config.url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 30000,
        readTimeout: 60000,
      }).then((_responseCode: number) => {
        // 流式响应：dataEnd 中处理完成逻辑
      }).catch(async (err: Error) => {
        if (this.destroyed) {
          return;
        }
        await this.writeQueue;
        await this.closeFile();
        reject(err);
      });
    });
  }

  // ═══════════════════════════════════════════════════════════
  // 文件操作
  // ═══════════════════════════════════════════════════════════

  /**
   * 打开目标文件（异步，不阻塞主线程）
   *
   * @param append true = 追加模式（断点续传），false = 截断创建（新下载）
   */
  private async openFile(append: boolean): Promise<void> {
    try {
      if (append) {
        // 断点续传：以追加模式打开，不截断已有数据
        this.file = await fileIo.open(
          this.filePath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND | fileIo.OpenMode.CREATE
        );
      } else {
        // 新下载：截断创建
        this.file = await fileIo.open(
          this.filePath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
        );
      }
      console.info(`[DownloadTask] 文件已打开: ${this.filePath}, append=${append}`);
    } catch (err) {
      console.error(`[DownloadTask] 打开文件失败: ${JSON.stringify(err)}`);
      throw err;
    }
  }

  /**
   * 安全关闭文件（等待写队列排空后关闭，不阻塞主线程）
   */
  private async closeFile(): Promise<void> {
    if (this.file) {
      // 等待所有排队的写操作完成
      await this.writeQueue;
      try {
        await fileIo.close(this.file);
      } catch (err) {
        console.warn(`[DownloadTask] 关闭文件异常: ${JSON.stringify(err)}`);
      }
      this.file = null;
      this.writeQueue = Promise.resolve();
    }
  }

  /**
   * 销毁 HTTP 请求（取消监听 → destroy）
   */
  private destroyHttpRequest(): void {
    if (this.httpRequest) {
      try {
        this.httpRequest.off('dataReceive');
        this.httpRequest.off('dataReceiveProgress');
        this.httpRequest.off('dataEnd');
        this.httpRequest.destroy();
      } catch (err) {
        console.warn(`[DownloadTask] 销毁 HTTP 请求异常: ${JSON.stringify(err)}`);
      }
      this.httpRequest = null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 进度 & 速度
  // ═══════════════════════════════════════════════════════════

  /**
   * 更新进度回调（定期持久化）
   */
  private async updateProgressCallback(): Promise<void> {
    const now = Date.now();

    // 每 5 秒持久化一次进度
    const persistDelta = now - this.lastPersistTime;
    if (persistDelta >= PERSIST_INTERVAL) {
      await updateTaskState(this.filesDir, this.tid, DownloadState.DOWNLOADING,
        this.downloadedBytes, this.totalBytes);
      this.lastPersistTime = now;
    }

    // 触发进度回调
    this.callbacks.onProgress?.(this.getProgress());
  }

  // ═══════════════════════════════════════════════════════════
  // 完成 & 失败处理
  // ═══════════════════════════════════════════════════════════

  /**
   * 处理下载完成
   */
  private async handleCompleted(): Promise<void> {
    if (this.destroyed) {
      return;
    }

    this.clearRetryTimer();
    this.downloadedBytes = this.totalBytes;

    this.setState(DownloadState.COMPLETED);
    await updateTaskState(this.filesDir, this.tid, DownloadState.COMPLETED,
      this.downloadedBytes, this.totalBytes);

    this.callbacks.onCompleted?.(this.tid, this.filePath);
    this.callbacks.onStateChange?.(this.tid, DownloadState.COMPLETED);

    console.info(`[DownloadTask] 下载完成, taskId: ${this.tid}, path: ${this.filePath}`);
  }

  /**
   * 统一失败处理 + 重试逻辑
   */
  private async handleFailure(errMsg: string): Promise<void> {
    if (this.destroyed) {
      return;
    }

    if (this.retryCount < this.maxRetries) {
      this.retryCount++;
      const delay = this.retryDelay * this.retryCount; // 递增延迟
      console.warn(
        `[DownloadTask] 重试 ${this.retryCount}/${this.maxRetries}, 延迟 ${delay}ms, taskId: ${this.tid}`);

      this.retryTimer = setTimeout(() => {
        this.retryResume();
      }, delay);
    } else {
      this.setState(DownloadState.FAILED);
      await updateTaskState(this.filesDir, this.tid, DownloadState.FAILED,
        this.downloadedBytes, this.totalBytes);
      this.callbacks.onFailed?.(this.tid, errMsg);
      console.error(`[DownloadTask] 下载最终失败（已重试 ${this.maxRetries} 次）, taskId: ${this.tid}`);
    }
  }

  /**
   * 重试：从已下载位置继续（带 Range 头）
   */
  private async retryResume(): Promise<void> {
    if (this.destroyed) {
      return;
    }

    try {
      await this.startHttpDownload(this.downloadedBytes);
      this.setState(DownloadState.DOWNLOADING);
      console.info(`[DownloadTask] 重试恢复成功（Range: bytes=${this.downloadedBytes}-）`);
    } catch (err) {
      await this.handleFailure(`重试失败: ${JSON.stringify(err)}`);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 工具方法
  // ═══════════════════════════════════════════════════════════

  /**
   * 生成唯一任务 ID
   */
  private generateTaskId(): string {
    return `dl_${Date.now()}`;
  }

  /**
   * 更新状态并通知回调
   */
  private setState(newState: DownloadState): void {
    if (this.state === newState) {
      return;
    }
    const oldState = this.state;
    this.state = newState;
    this.callbacks.onStateChange?.(this.tid, newState);
    console.info(`[DownloadTask] 状态: ${oldState} → ${newState}, taskId: ${this.tid}`);
  }

  /**
   * 持久化当前任务信息
   */
  private async persistTaskInfo(): Promise<void> {
    await saveTaskInfo(this.filesDir, {
      taskId: this.tid,
      url: this.config.url,
      filePath: this.filePath,
      downloadedBytes: this.downloadedBytes,
      totalBytes: this.totalBytes,
      state: this.state,
      label: this.config.label ?? '',
      metadata: this.config.metadata ?? {},
      createTime: Date.now(),
      updateTime: Date.now()
    });
  }

  /**
   * 清除重试定时器
   */
  private clearRetryTimer(): void {
    if (this.retryTimer !== null) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }
}
