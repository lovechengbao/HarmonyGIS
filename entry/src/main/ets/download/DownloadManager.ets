/**
 * DownloadManager — 离线地图下载管理器（基于 @ohos.net.http 直连）
 *
 * 面向宿主 App 和 WebView JS Bridge 的主要 API 入口。
 *
 * 核心能力：
 * - 多任务并发下载（可配置最大并发数）
 * - 断点续传（HTTP Range 头，应用退出 → 重启后自动恢复任务）
 * - 任务队列管理（超出并发数的任务排队等待）
 * - 进度回调（逐任务 + 全局）
 *
 * 使用流程：
 * 1. 宿主 App 初始化：const mgr = new DownloadManager(context.filesDir, { maxConcurrency: 3 })
 * 2. 初始化（恢复旧任务）：await mgr.initialize()
 * 3. 创建任务：const taskId = await mgr.createTask(config, callbacks)
 * 4. 控制：mgr.pauseTask(taskId) / mgr.resumeTask(taskId) / mgr.cancelTask(taskId)
 * 5. 退出前：await mgr.onDestroy()
 */

import fileIo from '@ohos.file.fs';
import { DownloadTask } from './DownloadTask';
import {
  DownloadCallbacks,
  DownloadConfig,
  DownloadProgress,
  DownloadState,
  DownloadTaskInfo
} from './DownloadTypes';
import {
  getAllTaskInfos,
  removeTaskInfo,
  saveTaskInfo,
  updateTaskState
} from './DownloadPersist';

/** 默认最大并发下载数 */
const DEFAULT_MAX_CONCURRENCY = 3;

/** 管理器初始化选项 */
export interface DownloadManagerOptions {
  maxConcurrency?: number;
}

/** 全局进度回调 */
export interface GlobalCallbacks {
  /** 所有任务进度总和 */
  onGlobalProgress?: (allProgress: DownloadProgress[], summary: DownloadSummary) => void;
  /** 单任务事件 */
  onTaskCompleted?: (taskId: string, filePath: string) => void;
  onTaskFailed?: (taskId: string, error: string) => void;
  onTaskStateChange?: (taskId: string, state: DownloadState) => void;
}

/** 全局下载摘要 */
export interface DownloadSummary {
  /** 总任务数 */
  totalTasks: number;
  /** 下载中任务数 */
  activeTasks: number;
  /** 已完成任务数 */
  completedTasks: number;
  /** 失败任务数 */
  failedTasks: number;
  /** 总下载字节数 */
  totalDownloadedBytes: number;
  /** 总需下载字节数 */
  totalBytes: number;
  /** 整体进度 0-100 */
  overallProgress: number;
}

export class DownloadManager {
  /** 活跃任务集合 taskId → DownloadTask */
  private activeTasks: Map<string, DownloadTask> = new Map();
  /** 等待队列（taskId 列表） */
  private pendingQueue: string[] = [];
  /** 任务配置缓存（用于重建） */
  private taskConfigs: Map<string, DownloadConfig> = new Map();
  /** 任务回调缓存 */
  private taskCallbacks: Map<string, DownloadCallbacks> = new Map();

  private maxConcurrency: number;
  private globalCallbacks: GlobalCallbacks | null = null;
  private filesDir: string;
  private initialized: boolean = false;

  /**
   * @param filesDir 应用沙箱 filesDir（用于持久化和文件保存）
   * @param options 可选配置
   */
  constructor(filesDir: string, options?: DownloadManagerOptions) {
    this.filesDir = filesDir;
    this.maxConcurrency = options?.maxConcurrency ?? DEFAULT_MAX_CONCURRENCY;
  }

  /**
   * 初始化管理器：恢复上次未完成的任务
   *
   * 应在宿主 App 的 onCreate / onPageShow 中调用。
   * 恢复的任务全部进入 PAUSED 状态（HTTP 连接无法跨进程存活），
   * 通过 resumeTask() 恢复时会自动带上 Range 头断点续传。
   */
  async initialize(globalCallbacks?: GlobalCallbacks): Promise<void> {
    if (this.initialized) {
      console.warn('[DownloadManager] 已经初始化，跳过');
      return;
    }

    this.globalCallbacks = globalCallbacks ?? null;
    console.info('[DownloadManager] 开始初始化...');

    // 从持久化中恢复任务
    const taskInfos = await getAllTaskInfos(this.filesDir);

    for (const info of taskInfos) {
      // 跳过已完成和已取消的任务
      if (info.state === DownloadState.COMPLETED ||
          info.state === DownloadState.CANCELLED) {
        continue;
      }

      // 跳过没有有效配置的任务
      if (!info.url || !info.filePath) {
        await removeTaskInfo(this.filesDir, info.taskId);
        continue;
      }

      // 创建任务实例并从持久化数据恢复
      const task = this.createTaskInstance(this.infoToConfig(info));
      task.recover(info.taskId, info.downloadedBytes, info.totalBytes);

      // 绑定回调
      const callbacks = this.buildTaskCallbacks(info.taskId);
      task.setCallbacks(callbacks);
      this.activeTasks.set(info.taskId, task);
      this.taskConfigs.set(info.taskId, this.infoToConfig(info));
      this.taskCallbacks.set(info.taskId, callbacks);

      // 恢复的任务全部加入等待队列（HTTP 连接已断，需手动 resume）
      this.pendingQueue.push(info.taskId);

      console.info(`[DownloadManager] 恢复任务: ${info.taskId}, 已下载: ${info.downloadedBytes}`);
    }

    // 启动等待队列中的任务（受并发限制）
    this.processPendingQueue();

    this.initialized = true;
    console.info(
      `[DownloadManager] 初始化完成, 活跃任务: ${this.activeTasks.size}, 等待: ${this.pendingQueue.length}`);
  }

  /**
   * 创建新的下载任务
   *
   * @param config 下载配置
   * @param callbacks 任务级回调
   * @returns taskId
   */
  async createTask(config: DownloadConfig, callbacks?: DownloadCallbacks): Promise<string> {
    // 检查是否已有相同 URL + filePath 的任务
    const existingId = await this.findExistingTask(config.url, config.saveDir + '/' + config.fileName);
    if (existingId) {
      const existingTask = this.activeTasks.get(existingId);
      if (existingTask) {
        const state = existingTask.getState();
        if (state === DownloadState.COMPLETED) {
          console.info(`[DownloadManager] 任务已存在且已完成: ${existingId}`);
          return existingId;
        }
        if (state === DownloadState.PAUSED) {
          await this.resumeTask(existingId);
          return existingId;
        }
        if (state === DownloadState.DOWNLOADING || state === DownloadState.PENDING) {
          console.info(`[DownloadManager] 任务已在下载/排队中: ${existingId}`);
          return existingId;
        }
      }
    }

    const task = this.createTaskInstance(config);
    const wrappedCallbacks = this.buildTaskCallbacks('');
    task.setCallbacks(wrappedCallbacks);

    // 检查并发限制
    const activeCount = this.countDownloadingTasks();

    // 生成 taskId：优先用 config 预指定的，否则内部生成
    if (config.taskId) {
      task.recover(config.taskId, 0, -1);
    } else {
      task.initTaskId();
    }
    const tid = task.getTaskId();

    const realCallbacks = this.buildTaskCallbacks(tid, callbacks);
    task.setCallbacks(realCallbacks);

    if (activeCount >= this.maxConcurrency) {
      // 并发已满：设为 PAUSED 后加入等待队列
      task.recover(tid, 0, -1);
      this.activeTasks.set(tid, task);
      this.taskConfigs.set(tid, config);
      this.taskCallbacks.set(tid, realCallbacks);

      await saveTaskInfo(this.filesDir, {
        taskId: tid,
        url: config.url,
        filePath: config.saveDir + '/' + config.fileName,
        downloadedBytes: 0,
        totalBytes: -1,
        state: DownloadState.PAUSED,
        label: config.label ?? '',
        metadata: config.metadata ?? {},
        headers: config.headers,
        networkType: config.networkType,
        maxRetries: config.maxRetries,
        retryDelay: config.retryDelay,
        createTime: Date.now(),
        updateTime: Date.now()
      });

      this.pendingQueue.push(tid);
      console.info(`[DownloadManager] 并发已满，任务 ${tid} 加入等待队列`);
      return tid;
    }

    // 直接启动：注册 + 异步开始下载（不 await，UI 立即响应）
    this.activeTasks.set(tid, task);
    this.taskConfigs.set(tid, config);
    this.taskCallbacks.set(tid, realCallbacks);

    // 持久化初始信息
    await saveTaskInfo(this.filesDir, {
      taskId: tid,
      url: config.url,
      filePath: config.saveDir + '/' + config.fileName,
      downloadedBytes: 0,
      totalBytes: -1,
      state: DownloadState.DOWNLOADING,
      label: config.label ?? '',
      metadata: config.metadata ?? {},
      headers: config.headers,
      networkType: config.networkType,
      maxRetries: config.maxRetries,
      retryDelay: config.retryDelay,
      createTime: Date.now(),
      updateTime: Date.now()
    });

    // 异步启动下载（不阻塞 createTask 返回）
    task.startDownload().catch((err: Error) => {
      console.error(`[DownloadManager] 启动下载失败: ${err.message}`);
    });

    console.info(`[DownloadManager] 创建并启动任务: ${tid}`);
    return tid;
  }

  /**
   * 暂停指定任务
   */
  async pauseTask(taskId: string): Promise<void> {
    const task = this.activeTasks.get(taskId);
    if (!task) {
      console.warn(`[DownloadManager] 任务不存在: ${taskId}`);
      return;
    }

    await task.pause();

    // 从等待队列中移除（如果存在）
    this.pendingQueue = this.pendingQueue.filter(id => id !== taskId);

    // 启动队列中的下一个任务
    this.processPendingQueue();
  }

  /**
   * 恢复指定任务（自动带 Range 头断点续传）
   */
  async resumeTask(taskId: string): Promise<void> {
    const task = this.activeTasks.get(taskId);
    if (!task) {
      console.warn(`[DownloadManager] 任务不存在: ${taskId}`);
      return;
    }

    if (task.getState() !== DownloadState.PAUSED) {
      console.warn(`[DownloadManager] 任务 ${taskId} 当前状态: ${task.getState()}, 无法恢复`);
      return;
    }

    const activeCount = this.countDownloadingTasks();
    if (activeCount >= this.maxConcurrency) {
      this.pendingQueue.push(taskId);
      console.info(`[DownloadManager] 并发已满，任务 ${taskId} 加入等待队列`);
      return;
    }

    // 从等待队列中移除
    this.pendingQueue = this.pendingQueue.filter(id => id !== taskId);

    await task.resume();
    console.info(`[DownloadManager] 恢复任务: ${taskId}`);
  }

  /**
   * 取消并删除指定任务
   */
  async cancelTask(taskId: string, deleteFile: boolean = false): Promise<void> {
    const task = this.activeTasks.get(taskId);
    if (!task) {
      // 仅从持久化中清理
      await removeTaskInfo(this.filesDir, taskId);
      return;
    }

    // 如果需要删除已下载的文件
    if (deleteFile) {
      const filePath = task.getFilePath();
      try {
        fileIo.unlinkSync(filePath);
        console.info(`[DownloadManager] 已删除文件: ${filePath}`);
      } catch (_err) {
        // 文件可能不存在或已删除，忽略错误
        console.warn(`[DownloadManager] 删除文件失败: ${filePath}`);
      }
    }

    await task.cancel();
    this.activeTasks.delete(taskId);
    this.taskConfigs.delete(taskId);
    this.taskCallbacks.delete(taskId);

    // 从等待队列中移除
    this.pendingQueue = this.pendingQueue.filter(id => id !== taskId);

    // 启动队列中的下一个任务
    this.processPendingQueue();

    console.info(`[DownloadManager] 已取消任务: ${taskId}`);
  }

  /**
   * 暂停所有活跃任务
   */
  async pauseAll(): Promise<void> {
    const promises: Promise<void>[] = [];
    for (const task of this.activeTasks.values()) {
      if (task.getState() === DownloadState.DOWNLOADING) {
        promises.push(task.pause());
      }
    }
    this.pendingQueue = [];
    await Promise.all(promises);
    console.info('[DownloadManager] 已暂停所有任务');
  }

  /**
   * 恢复所有已暂停任务（受并发限制）
   */
  async resumeAll(): Promise<void> {
    this.activeTasks.forEach((task: DownloadTask, tid: string) => {
      if (task.getState() === DownloadState.PAUSED) {
        this.pendingQueue.push(tid);
      }
    });
    this.processPendingQueue();
    console.info('[DownloadManager] 开始恢复所有任务');
  }

  /**
   * 获取指定任务详情
   */
  getTask(taskId: string): DownloadTaskInfo | null {
    const taskInfos = getAllTaskInfos(this.filesDir);
    // getAllTaskInfos 返回 Promise<DownloadTaskInfo[]>，但这里同步返回已有数据
    // 从活跃任务中获取
    const task = this.activeTasks.get(taskId);
    if (task) {
      return {
        taskId: task.getTaskId(),
        url: this.taskConfigs.get(taskId)?.url ?? '',
        filePath: task.getFilePath(),
        downloadedBytes: task.getProgress().downloadedBytes,
        totalBytes: task.getProgress().totalBytes,
        state: task.getState(),
        label: this.taskConfigs.get(taskId)?.label ?? '',
        metadata: this.taskConfigs.get(taskId)?.metadata ?? {},
        createTime: 0,
        updateTime: Date.now()
      };
    }
    return null;
  }

  /**
   * 获取指定任务的进度
   */
  getTaskProgress(taskId: string): DownloadProgress | null {
    const task = this.activeTasks.get(taskId);
    return task ? task.getProgress() : null;
  }

  /**
   * 获取服务器返回的文件名（Content-Disposition）
   */
  getServerFileName(taskId: string): string {
    const task = this.activeTasks.get(taskId);
    return task ? task.getServerFileName() : '';
  }

  /**
   * 获取所有任务的进度
   */
  getAllProgress(): DownloadProgress[] {
    const progressList: DownloadProgress[] = [];
    this.activeTasks.forEach((task: DownloadTask) => {
      progressList.push(task.getProgress());
    });
    return progressList;
  }

  /**
   * 获取下载摘要
   */
  getSummary(): DownloadSummary {
    let totalDownloaded = 0;
    let totalSize = 0;
    let active = 0;
    let completed = 0;
    let failed = 0;

    this.activeTasks.forEach((task: DownloadTask) => {
      const progress = task.getProgress();
      totalDownloaded += progress.downloadedBytes;
      if (progress.totalBytes > 0) {
        totalSize += progress.totalBytes;
      }

      console.info(`[DownloadManager] getSummary: task state=${progress.state}, downloaded=${progress.downloadedBytes}, total=${progress.totalBytes}`);

      switch (progress.state) {
        case DownloadState.DOWNLOADING:
          active++;
          break;
        case DownloadState.COMPLETED:
          completed++;
          break;
        case DownloadState.FAILED:
          failed++;
          break;
      }
    });

    const overallProgress = totalSize > 0 ?
      Math.round((totalDownloaded / totalSize) * 100) :
      0;

    const summary: DownloadSummary = {
      totalTasks: this.activeTasks.size,
      activeTasks: active,
      completedTasks: completed,
      failedTasks: failed,
      totalDownloadedBytes: totalDownloaded,
      totalBytes: totalSize,
      overallProgress: overallProgress
    };
    return summary;
  }

  /**
   * 获取所有任务列表（供 UI 展示）
   */
  async getTaskList(): Promise<DownloadTaskInfo[]> {
    return await getAllTaskInfos(this.filesDir);
  }

  /**
   * 检查是否有活跃下载
   */
  hasActiveDownloads(): boolean {
    return this.countDownloadingTasks() > 0;
  }

  /**
   * 生命周期：销毁前调用
   *
   * 应在宿主 App 的 onDestroy / onPageHide 中调用
   */
  async onDestroy(): Promise<void> {
    console.info('[DownloadManager] onDestroy — 暂停所有活跃任务...');

    const destroyPromises: Promise<void>[] = [];
    this.activeTasks.forEach((task: DownloadTask, _tid: string) => {
      if (task.getState() === DownloadState.DOWNLOADING) {
        destroyPromises.push(task.destroy());
      }
    });
    await Promise.all(destroyPromises);

    this.pendingQueue = [];
    console.info(`[DownloadManager] 已销毁。活跃任务数: ${this.activeTasks.size}`);
  }

  /**
   * 更新全局回调
   */
  setGlobalCallbacks(callbacks: GlobalCallbacks): void {
    this.globalCallbacks = callbacks;
  }

  /**
   * 更新指定任务的回调
   */
  updateTaskCallbacks(taskId: string, callbacks: DownloadCallbacks): void {
    const task = this.activeTasks.get(taskId);
    if (task) {
      const merged = this.buildTaskCallbacks(taskId, callbacks);
      task.setCallbacks(merged);
      this.taskCallbacks.set(taskId, merged);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 内部方法
  // ═══════════════════════════════════════════════════════════

  /**
   * 处理等待队列，启动排队任务（受并发限制）
   */
  private async processPendingQueue(): Promise<void> {
    while (this.pendingQueue.length > 0 &&
           this.countDownloadingTasks() < this.maxConcurrency) {
      const taskId = this.pendingQueue.shift()!;
      const task = this.activeTasks.get(taskId);

      if (!task) {
        continue;
      }

      if (task.getState() === DownloadState.PAUSED) {
        await task.resume();
        console.info(`[DownloadManager] 从队列中启动任务: ${taskId}`);
      }
    }
  }

  /**
   * 统计当前正在下载的任务数
   */
  private countDownloadingTasks(): number {
    let count = 0;
    for (const task of this.activeTasks.values()) {
      if (task.getState() === DownloadState.DOWNLOADING) {
        count++;
      }
    }
    return count;
  }

  /**
   * 创建 DownloadTask 实例
   */
  private createTaskInstance(config: DownloadConfig): DownloadTask {
    return new DownloadTask(config, {}, this.filesDir);
  }

  /**
   * 构建任务回调（包装全局回调 + 任务级回调）
   */
  private buildTaskCallbacks(taskId: string, extra?: DownloadCallbacks): DownloadCallbacks {
    const g = this.globalCallbacks;
    return {
      onProgress: (progress: DownloadProgress) => {
        extra?.onProgress?.(progress);
        if (g?.onGlobalProgress) {
          g.onGlobalProgress(this.getAllProgress(), this.getSummary());
        }
      },
      onCompleted: (tid: string, filePath: string) => {
        extra?.onCompleted?.(tid, filePath);
        g?.onTaskCompleted?.(tid, filePath);
        // 完成一个任务后，处理排队
        this.processPendingQueue();
      },
      onFailed: (tid: string, error: string) => {
        extra?.onFailed?.(tid, error);
        g?.onTaskFailed?.(tid, error);
        // 失败后也处理排队
        this.processPendingQueue();
      },
      onPaused: (tid: string) => {
        extra?.onPaused?.(tid);
        g?.onTaskStateChange?.(tid, DownloadState.PAUSED);
      },
      onStateChange: (tid: string, state: DownloadState) => {
        extra?.onStateChange?.(tid, state);
        g?.onTaskStateChange?.(tid, state);
      }
    };
  }

  /**
   * 查找已存在的任务（根据 URL + filePath）
   */
  private async findExistingTask(url: string, filePath: string): Promise<string | null> {
    let existing: string | null = null;
    this.activeTasks.forEach((task: DownloadTask, tid: string) => {
      if (task.getFilePath() === filePath) {
        existing = tid;
      }
    });
    if (existing !== null) {
      return existing;
    }

    // 也检查持久化中的已完成任务
    const allInfos = await getAllTaskInfos(this.filesDir);
    for (let i = 0; i < allInfos.length; i++) {
      const info = allInfos[i];
      if (info.filePath === filePath && info.state === DownloadState.COMPLETED) {
        return info.taskId;
      }
    }

    return null;
  }

  /**
   * 从 DownloadTaskInfo 重建 DownloadConfig
   */
  private infoToConfig(info: DownloadTaskInfo): DownloadConfig {
    const lastSlash = info.filePath.lastIndexOf('/');
    const saveDir = info.filePath.substring(0, lastSlash);
    const fileName = info.filePath.substring(lastSlash + 1);

    return {
      url: info.url,
      saveDir: saveDir,
      fileName: fileName,
      label: info.label,
      metadata: info.metadata,
      headers: info.headers,
      networkType: info.networkType,
      maxRetries: info.maxRetries,
      retryDelay: info.retryDelay
    };
  }
}
