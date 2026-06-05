/**
 * OfflineMap — 离线地图下载核心类（全静态方法）
 *
 * 包装 DownloadManager，提供面向地图业务的上层 API：
 * - downloadMap: 启动/恢复下载（返回 Promise，完成/暂停/失败时 resolve）
 * - getProgress: 获取下载进度百分比
 * - pauseDownloadingMap: 暂停下载
 *
 * 调用模式：
 *   OfflineMap.init(downloadManager, filesDir + '/offlineMaps');
 *   const result = await OfflineMap.downloadMap(url, mapId, 'offlineMap', true);
 *
 * 后续扩展：解压离线包、SQLite 元信息存储
 */

import { DownloadManager } from './DownloadManager';
import { DownloadCallbacks, DownloadConfig, DownloadState } from './DownloadTypes';

/** 下载结果状态码：下载完成 */
const RESULT_COMPLETED = 0;
/** 下载结果状态码：已暂停 */
const RESULT_PAUSED = -50;
/** 下载结果状态码：错误 */
const RESULT_ERROR = -1;

export class OfflineMap {
  private static mgr: DownloadManager;
  private static saveDir: string;
  /** mapId → taskId 映射 */
  private static mapTasks: Map<string, string> = new Map();
  /** mapId → resolve 函数（唤醒等待中的 downloadMap Promise） */
  private static resolvers: Map<string, (result: number) => void> = new Map();
  /** mapId → 正在等待的 Promise（防止并发重复调用 downloadMap） */
  private static pendingPromises: Map<string, Promise<number>> = new Map();

  /**
   * 初始化（必须在调用其他方法前执行）
   *
   * @param mgr 已初始化的 DownloadManager 实例
   * @param saveDir 离线地图保存目录（绝对路径）
   */
  static init(mgr: DownloadManager, saveDir: string): void {
    OfflineMap.mgr = mgr;
    OfflineMap.saveDir = saveDir;
  }

  /**
   * 启动或恢复地图下载
   *
   * 行为：
   * - 首次调用：创建新的下载任务，返回 Promise
   * - 下载中重复调用：返回同一个 Promise（不会重复创建）
   * - 暂停后再次调用：恢复下载（断点续传），返回新的 Promise
   * - 已完成：直接返回 0
   *
   * @param url 地图包下载地址
   * @param mapId 地图唯一标识
   * @param tag 任务标签（用于日志/UI）
   * @param overwrite 是否覆盖已完成的下载（预留，暂未实现）
   * @returns Promise<number> — 0=完成, -50=已暂停, -1=错误
   */
  static async downloadMap(url: string, mapId: string, tag: string, overwrite: boolean): Promise<number> {
    // 已有等待中的 Promise（下载中 / 恢复中重复调用）
    const existing = OfflineMap.pendingPromises.get(mapId);
    if (existing) {
      console.info(`[OfflineMap] mapId ${mapId} 已有等待中的下载，返回已有 Promise`);
      return existing;
    }

    const existingTaskId = OfflineMap.mapTasks.get(mapId);

    if (existingTaskId) {
      const info = OfflineMap.mgr.getTask(existingTaskId);
      if (info) {
        if (info.state === DownloadState.COMPLETED) {
          console.info(`[OfflineMap] mapId ${mapId} 已完成下载`);
          return RESULT_COMPLETED;
        }

        if (info.state === DownloadState.PAUSED) {
          console.info(`[OfflineMap] mapId ${mapId} 已暂停，恢复下载（断点续传）`);
          // 先更新回调（确保新 Promise 的 resolver 在 resume 之前就位）
          OfflineMap.mgr.updateTaskCallbacks(existingTaskId, OfflineMap.buildCallbacks(mapId));

          const promise = new Promise<number>((resolve: (result: number) => void) => {
            OfflineMap.resolvers.set(mapId, resolve);
          });
          OfflineMap.pendingPromises.set(mapId, promise);

          try {
            await OfflineMap.mgr.resumeTask(existingTaskId);
          } catch (err) {
            const e = err as Error;
            console.error(`[OfflineMap] 恢复下载失败: mapId=${mapId}, error=${e.message}`);
            const r = OfflineMap.resolvers.get(mapId);
            if (r) {
              r(RESULT_ERROR);
              OfflineMap.resolvers.delete(mapId);
              OfflineMap.pendingPromises.delete(mapId);
            }
          }
          return promise;
        }
      }
    }

    // 新建下载任务
    console.info(`[OfflineMap] 创建新下载任务: mapId=${mapId}, url=${url}`);
    const promise = new Promise<number>((resolve: (result: number) => void) => {
      OfflineMap.resolvers.set(mapId, resolve);

      const config: DownloadConfig = {
        url: url,
        saveDir: OfflineMap.saveDir,
        fileName: mapId + '.zip',
        label: tag,
        metadata: { mapId: mapId }
      };

      OfflineMap.mgr.createTask(config, OfflineMap.buildCallbacks(mapId)).then((taskId: string) => {
        OfflineMap.mapTasks.set(mapId, taskId);
        console.info(`[OfflineMap] 下载任务已创建: taskId=${taskId}, mapId=${mapId}`);
      }).catch((err: Error) => {
        console.error(`[OfflineMap] 创建任务失败: mapId=${mapId}, error=${err.message}`);
        const r = OfflineMap.resolvers.get(mapId);
        if (r) {
          r(RESULT_ERROR);
          OfflineMap.resolvers.delete(mapId);
          OfflineMap.pendingPromises.delete(mapId);
        }
      });
    });

    OfflineMap.pendingPromises.set(mapId, promise);
    return promise;
  }

  /**
   * 获取指定地图的下载进度
   *
   * @param mapId 地图唯一标识
   * @returns 0-100 的百分比，不存在返回 -1
   */
  static getProgress(mapId: string): number {
    const taskId = OfflineMap.mapTasks.get(mapId);
    if (!taskId) {
      return -1;
    }
    const progress = OfflineMap.mgr.getTaskProgress(taskId);
    if (!progress) {
      return -1;
    }
    return progress.progress;
  }

  /**
   * 暂停指定地图的下载
   *
   * 调用后 downloadMap 的 Promise 会以 -50 resolve。
   * 之后可通过 downloadMap 恢复下载（断点续传）。
   *
   * @param mapId 地图唯一标识
   */
  static async pauseDownloadingMap(mapId: string): Promise<void> {
    const taskId = OfflineMap.mapTasks.get(mapId);
    if (!taskId) {
      console.warn(`[OfflineMap] 暂停失败，mapId 不存在: ${mapId}`);
      return;
    }
    console.info(`[OfflineMap] 暂停下载: mapId=${mapId}, taskId=${taskId}`);
    await OfflineMap.mgr.pauseTask(taskId);
  }

  // ═══════════════════════════════════════════════════════════
  // 内部方法
  // ═══════════════════════════════════════════════════════════

  /**
   * 构建 DownloadManager 回调
   * 将任务事件（完成/失败/暂停）转为 mapId 维度的 Promise resolve
   */
  private static buildCallbacks(mapId: string): DownloadCallbacks {
    return {
      onCompleted: (_taskId: string, _filePath: string) => {
        console.info(`[OfflineMap] 下载完成: mapId=${mapId}`);
        const r = OfflineMap.resolvers.get(mapId);
        if (r) {
          r(RESULT_COMPLETED);
          OfflineMap.resolvers.delete(mapId);
          OfflineMap.pendingPromises.delete(mapId);
        }
      },
      onFailed: (_taskId: string, error: string) => {
        console.error(`[OfflineMap] 下载失败: mapId=${mapId}, error=${error}`);
        const r = OfflineMap.resolvers.get(mapId);
        if (r) {
          r(RESULT_ERROR);
          OfflineMap.resolvers.delete(mapId);
          OfflineMap.pendingPromises.delete(mapId);
        }
      },
      onPaused: (_taskId: string) => {
        console.info(`[OfflineMap] 下载已暂停: mapId=${mapId}`);
        const r = OfflineMap.resolvers.get(mapId);
        if (r) {
          r(RESULT_PAUSED);
          OfflineMap.resolvers.delete(mapId);
          OfflineMap.pendingPromises.delete(mapId);
        }
      }
    };
  }
}
