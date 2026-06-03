/**
 * DownloadTask — 单个下载任务封装
 *
 * 包装 @ohos.request.agent 的单个下载任务，提供：
 * - 任务生命周期管理（创建/启动/暂停/恢复/删除）
 * - 进度/速度上报
 * - 失败自动重试
 * - 断点续传（通过 request.agent.getTask 恢复系统级任务）
 */

import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import {
  DownloadCallbacks,
  DownloadConfig,
  DownloadEvent,
  DownloadNetworkType,
  DownloadProgress,
  DownloadState
} from './DownloadTypes';
import { saveTaskInfo, removeTaskInfo, updateTaskState } from './DownloadPersist';

/** 速度计算采样间隔 (ms) */
const SPEED_SAMPLE_INTERVAL = 1000;
/** 默认最大重试次数 */
const DEFAULT_MAX_RETRIES = 3;
/** 默认重试间隔 (ms) */
const DEFAULT_RETRY_DELAY = 5000;

export class DownloadTask {
  /** 系统级 taskId */
  private tid: string = '';
  /** request.agent 任务实例 */
  private agentTask: request.agent.Task | null = null;
  /** 任务配置 */
  private config: DownloadConfig;
  /** 回调集合 */
  private callbacks: DownloadCallbacks;
  /** 当前状态 */
  private state: DownloadState = DownloadState.PENDING;
  /** 完整保存路径 */
  private filePath: string = '';
  /** Context */
  private context: common.UIAbilityContext;
  /** filesDir（持久化用） */
  private filesDir: string;

  // ── 进度跟踪 ──
  private downloadedBytes: number = 0;
  private totalBytes: number = -1;
  private lastSampleTime: number = 0;
  private lastSampleBytes: number = 0;
  private currentSpeed: number = 0;

  // ── 重试 ──
  private retryCount: number = 0;
  private maxRetries: number;
  private retryDelay: number;
  private retryTimer: number | null = null;

  /** 是否已销毁 */
  private destroyed: boolean = false;

  // ── 事件监听器引用（用于 off）──
  private onProgressHandler: ((progress: request.agent.Progress) => void) | null = null;
  private onCompletedHandler: ((progress: request.agent.Progress) => void) | null = null;
  private onFailedHandler: ((progress: request.agent.Progress) => void) | null = null;

  constructor(context: common.UIAbilityContext, config: DownloadConfig, callbacks: DownloadCallbacks) {
    this.context = context;
    this.config = config;
    this.callbacks = callbacks;
    this.maxRetries = config.maxRetries ?? DEFAULT_MAX_RETRIES;
    this.retryDelay = config.retryDelay ?? DEFAULT_RETRY_DELAY;
    this.filePath = config.saveDir + '/' + config.fileName;
    this.filesDir = context.filesDir;
  }

  /**
   * 获取系统级 taskId
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
      speed: this.currentSpeed,
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
   * 创建并启动下载任务（新任务）
   */
  async start(): Promise<void> {
    if (this.destroyed) {
      return;
    }

    try {
      await this.createAgentTask();
      this.setState(DownloadState.DOWNLOADING);
      this.lastSampleTime = Date.now();
      this.lastSampleBytes = 0;

      await this.agentTask!.start();
      console.info(`[DownloadTask] 下载启动成功, taskId: ${this.tid}`);

      // 持久化
      this.persistTaskInfo();
    } catch (err) {
      const msg = `启动下载失败: ${JSON.stringify(err)}`;
      console.error(`[DownloadTask] ${msg}`);
      this.handleFailure(msg);
    }
  }

  /**
   * 暂停下载
   */
  async pause(): Promise<void> {
    if (!this.agentTask || this.state !== DownloadState.DOWNLOADING) {
      return;
    }

    try {
      await this.agentTask.pause();
      this.setState(DownloadState.PAUSED);
      updateTaskState(this.filesDir, this.tid, DownloadState.PAUSED, this.downloadedBytes,
        this.totalBytes);
      this.callbacks.onPaused?.(this.tid);
      this.emitEvent(DownloadEvent.PAUSED, this.tid);
      console.info(`[DownloadTask] 已暂停, taskId: ${this.tid}`);
    } catch (err) {
      console.error(`[DownloadTask] 暂停失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 恢复下载（断点续传）
   */
  async resume(): Promise<void> {
    if (!this.agentTask || this.state !== DownloadState.PAUSED) {
      return;
    }

    try {
      // 删除旧任务，用已下载字节偏移重建，确保 Range 头正确
      this.removeEventListeners();
      await this.agentTask.delete();
      this.agentTask = null;

      await this.createAgentTask(this.downloadedBytes);
      this.setState(DownloadState.DOWNLOADING);
      this.lastSampleTime = Date.now();
      this.lastSampleBytes = this.downloadedBytes;
      this.retryCount = 0;

      await this.agentTask!.start();
      this.persistTaskInfo();
      console.info(`[DownloadTask] 已恢复下载（断点续传, begins=${this.downloadedBytes}）, taskId: ${this.tid}`);
    } catch (err) {
      const msg = `恢复下载失败: ${JSON.stringify(err)}`;
      console.error(`[DownloadTask] ${msg}`);
      this.handleFailure(msg);
    }
  }

  /**
   * 取消并删除任务
   */
  async cancel(): Promise<void> {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.clearRetryTimer();

    if (this.agentTask) {
      try {
        this.removeEventListeners();
        await this.agentTask.delete();
      } catch (err) {
        console.warn(`[DownloadTask] 删除任务异常: ${JSON.stringify(err)}`);
      }
    }

    this.setState(DownloadState.CANCELLED);
    removeTaskInfo(this.filesDir, this.tid);
    console.info(`[DownloadTask] 已取消, taskId: ${this.tid}`);
  }

  /**
   * 通过已有的系统 taskId 恢复任务（应用重启后使用）
   */
  async recover(tid: string): Promise<boolean> {
    this.tid = tid;

    try {
      this.agentTask = await request.agent.getTask(this.context, tid);
      if (!this.agentTask) {
        console.warn(`[DownloadTask] getTask 返回 null, tid: ${tid}`);
        return false;
      }

      this.registerEventListeners();

      // 查询当前状态
      const taskInfo = await this.agentTask.query();
      this.downloadedBytes = taskInfo.processed;
      this.totalBytes = taskInfo.sizes;

      // 根据系统状态推断
      const agentState = taskInfo.state;
      if (agentState === request.agent.State.RUNNING) {
        this.setState(DownloadState.DOWNLOADING);
        this.lastSampleTime = Date.now();
        this.lastSampleBytes = this.downloadedBytes;
      } else if (agentState === request.agent.State.PAUSED ||
                 agentState === request.agent.State.WAITING ||
                 agentState === request.agent.State.STOPPED) {
        this.setState(DownloadState.PAUSED);
      } else if (agentState === request.agent.State.COMPLETED) {
        this.setState(DownloadState.COMPLETED);
      }

      console.info(`[DownloadTask] 恢复任务成功, tid: ${tid}, state: ${this.state}`);
      return true;
    } catch (err) {
      // 任务可能已过期，从持久化中移除
      console.error(`[DownloadTask] 恢复任务失败, tid: ${tid}: ${JSON.stringify(err)}`);
      removeTaskInfo(this.filesDir, tid);
      this.setState(DownloadState.FAILED);
      return false;
    }
  }

  /**
   * 更新回调（用于恢复任务后重新绑定回调）
   */
  setCallbacks(callbacks: DownloadCallbacks): void {
    this.callbacks = callbacks;
  }

  /**
   * 销毁（暂停任务，但不删除）
   */
  async destroy(): Promise<void> {
    this.destroyed = true;
    this.clearRetryTimer();

    if (this.agentTask && this.state === DownloadState.DOWNLOADING) {
      try {
        await this.agentTask.pause();
        this.setState(DownloadState.PAUSED);
        updateTaskState(this.filesDir, this.tid, DownloadState.PAUSED, this.downloadedBytes,
          this.totalBytes);
        console.info(`[DownloadTask] 销毁时已暂停任务, tid: ${this.tid}`);
      } catch (err) {
        console.warn(`[DownloadTask] 销毁时暂停异常: ${JSON.stringify(err)}`);
      }
    }
    this.removeEventListeners();
    this.agentTask = null;
  }

  // ═══════════════════════════════════════════════════════════
  // 内部方法
  // ═══════════════════════════════════════════════════════════

  /**
   * 创建 request.agent 任务
   */
  private async createAgentTask(begins: number = 0): Promise<void> {
    const network = this.config.networkType === DownloadNetworkType.WIFI ?
      request.agent.Network.WIFI :
      request.agent.Network.ANY;

    const agentConfig: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      url: this.config.url,
      saveas: this.filePath,
      overwrite: true,
      method: 'GET',
      mode: request.agent.Mode.BACKGROUND,  // 必须 BACKGROUND 才能断点续传
      gauge: true,
      retry: false,  // 我们自己管理重试逻辑
      network: network,
      title: this.config.label ?? 'HarmonyGIS Offline Map',
      begins: begins,
      ends: -1
    };

    // 可选：自定义请求头
    if (this.config.headers && Object.keys(this.config.headers).length > 0) {
      agentConfig.headers = this.config.headers;
    }

    this.agentTask = await request.agent.create(this.context, agentConfig);
    this.tid = this.agentTask.tid;
    this.registerEventListeners();
    console.info(`[DownloadTask] 创建 agent 任务成功, tid: ${this.tid}`);
  }

  /**
   * 注册进度/完成/失败事件监听
   */
  private registerEventListeners(): void {
    if (!this.agentTask) {
      return;
    }

    this.onProgressHandler = (progress: request.agent.Progress) => {
      this.handleProgress(progress);
    };

    this.onCompletedHandler = (_progress: request.agent.Progress) => {
      this.handleCompleted();
    };

    this.onFailedHandler = (progress: request.agent.Progress) => {
      this.handleAgentFailed(progress);
    };

    this.agentTask.on('progress', this.onProgressHandler);
    this.agentTask.on('completed', this.onCompletedHandler);
    this.agentTask.on('failed', this.onFailedHandler);
  }

  /**
   * 移除事件监听
   */
  private removeEventListeners(): void {
    if (!this.agentTask) {
      return;
    }

    if (this.onProgressHandler) {
      this.agentTask.off('progress', this.onProgressHandler);
    }
    if (this.onCompletedHandler) {
      this.agentTask.off('completed', this.onCompletedHandler);
    }
    if (this.onFailedHandler) {
      this.agentTask.off('failed', this.onFailedHandler);
    }

    this.onProgressHandler = null;
    this.onCompletedHandler = null;
    this.onFailedHandler = null;
  }

  /**
   * 处理进度更新
   */
  private handleProgress(progress: request.agent.Progress): void {
    if (this.destroyed) {
      return;
    }

    this.downloadedBytes = progress.processed;
    this.totalBytes = progress.sizes;

    // 计算速度
    const now = Date.now();
    const timeDelta = now - this.lastSampleTime;
    if (timeDelta >= SPEED_SAMPLE_INTERVAL) {
      const bytesDelta = this.downloadedBytes - this.lastSampleBytes;
      this.currentSpeed = timeDelta > 0 ?
        Math.round((bytesDelta / timeDelta) * 1000) :
        0;
      this.lastSampleTime = now;
      this.lastSampleBytes = this.downloadedBytes;
    }

    // 定期持久化进度
    if (timeDelta >= 5000) {
      updateTaskState(this.filesDir, this.tid, DownloadState.DOWNLOADING,
        this.downloadedBytes, this.totalBytes);
    }

    // 触发回调
    this.callbacks.onProgress?.(this.getProgress());
  }

  /**
   * 处理下载完成
   */
  private handleCompleted(): void {
    if (this.destroyed) {
      return;
    }

    this.clearRetryTimer();
    this.downloadedBytes = this.totalBytes;
    this.state = DownloadState.COMPLETED;
    updateTaskState(this.filesDir, this.tid, DownloadState.COMPLETED,
      this.downloadedBytes, this.totalBytes);

    this.currentSpeed = 0;

    this.callbacks.onCompleted?.(this.tid, this.filePath);
    this.callbacks.onStateChange?.(this.tid, DownloadState.COMPLETED);
    this.emitEvent(DownloadEvent.COMPLETED, this.tid);

    console.info(`[DownloadTask] 下载完成, tid: ${this.tid}, path: ${this.filePath}`);
  }

  /**
   * 处理 agent 层的失败
   */
  private handleAgentFailed(progress: request.agent.Progress): void {
    if (this.destroyed) {
      return;
    }

    const errMsg = progress.faults?.toString() ?? '未知错误';
    console.error(`[DownloadTask] agent 失败, tid: ${this.tid}, 原因: ${errMsg}`);
    this.handleFailure(errMsg);
  }

  /**
   * 统一失败处理 + 重试逻辑
   */
  private handleFailure(errMsg: string): void {
    if (this.destroyed) {
      return;
    }

    if (this.retryCount < this.maxRetries) {
      this.retryCount++;
      const delay = this.retryDelay * this.retryCount;  // 递增延迟
      console.warn(
        `[DownloadTask] 重试 ${this.retryCount}/${this.maxRetries}, 延迟 ${delay}ms, tid: ${this.tid}`);

      this.retryTimer = setTimeout(() => {
        // 注意：这里不能用 await，需要在定时器回调中处理
        this.retryResume();
      }, delay);
    } else {
      this.setState(DownloadState.FAILED);
      updateTaskState(this.filesDir, this.tid, DownloadState.FAILED,
        this.downloadedBytes, this.totalBytes);
      this.callbacks.onFailed?.(this.tid, errMsg);
      console.error(`[DownloadTask] 下载最终失败（已重试 ${this.maxRetries} 次）, tid: ${this.tid}`);
    }
  }

  /**
   * 重试：通过 resume 继续下载
   */
  private async retryResume(): Promise<void> {
    if (this.destroyed || !this.agentTask) {
      return;
    }

    try {
      // 如果 agentTask 还存在，尝试 resume（系统会自动断点续传）
      await this.agentTask.resume();
      this.setState(DownloadState.DOWNLOADING);
      console.info(`[DownloadTask] 重试恢复成功, tid: ${this.tid}`);
    } catch (err) {
      // resume 失败，尝试重新创建任务
      console.warn(`[DownloadTask] resume 重试失败，尝试重建任务: ${JSON.stringify(err)}`);
      try {
        await this.agentTask.delete();
      } catch (_e) {
        // ignore
      }
      this.agentTask = null;

      try {
        await this.createAgentTask(this.downloadedBytes);
        await this.agentTask!.start();
        this.setState(DownloadState.DOWNLOADING);
        console.info(`[DownloadTask] 重建任务重试成功（断点续传, begins=${this.downloadedBytes}）, tid: ${this.tid}`);
      } catch (createErr) {
        const msg = `重建任务失败: ${JSON.stringify(createErr)}`;
        console.error(`[DownloadTask] ${msg}`);
        this.handleFailure(msg);
      }
    }
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
    console.info(`[DownloadTask] 状态: ${oldState} → ${newState}, tid: ${this.tid}`);
  }

  /**
   * 持久化当前任务信息
   */
  private persistTaskInfo(): void {
    saveTaskInfo(this.filesDir, {
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

  /**
   * 发送自定义事件（预留：后续可扩展 EventEmitter）
   */
  private emitEvent(event: DownloadEvent, taskId: string): void {
    // 预留事件总线接口
    // 当前通过 callbacks 直接通知，后续可接入应用级事件总线
  }
}
