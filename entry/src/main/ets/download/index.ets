/**
 * HarmonyGIS 离线地图下载模块
 *
 * 使用示例：
 *
 * ```typescript
 * import { DownloadManager, DownloadConfig, DownloadState } from '../download/index';
 *
 * // 1. 初始化
 * const mgr = new DownloadManager(context.filesDir, { maxConcurrency: 3 });
 * await mgr.initialize({
 *   onGlobalProgress: (all, summary) => { console.log(`总进度: ${summary.overallProgress}%`) },
 *   onTaskCompleted: (tid, path) => { console.log(`完成: ${tid}`) },
 * });
 *
 * // 2. 创建下载任务
 * const taskId = await mgr.createTask({
 *   url: 'https://tile.openstreetmap.org/12/3421/2211.png',
 *   saveDir: context.filesDir + '/maps',
 *   fileName: 'tile_12_3421_2211.png',
 *   label: 'OSM 瓦片 (12/3421/2211)',
 * }, {
 *   onProgress: (p) => { console.log(`下载中: ${p.progress}%`) },
 * });
 *
 * // 3. 控制
 * await mgr.pauseTask(taskId);
 * await mgr.resumeTask(taskId);
 * await mgr.cancelTask(taskId);
 *
 * // 4. 退出前
 * await mgr.onDestroy();
 * ```
 */

export { DownloadManager } from './DownloadManager';
export type { DownloadManagerOptions, GlobalCallbacks, DownloadSummary } from './DownloadManager';

export { DownloadTask } from './DownloadTask';

export {
  DownloadState,
  DownloadNetworkType,
  DownloadEvent
} from './DownloadTypes';

export type {
  DownloadConfig,
  DownloadProgress,
  DownloadTaskInfo,
  DownloadCallbacks,
  PersistRecord,
  HttpProgressData
} from './DownloadTypes';

export { HttpResumeDownloader, ResumeDownloaderState } from './HttpResumeDownloader';
export type {
  HttpResumeDownloaderOptions,
  ProgressSnapshot,
  ResumeProgressCallback,
  ResumeCompleteCallback,
  ResumeErrorCallback
} from './HttpResumeDownloader';

export {
  loadPersistRecord,
  savePersistRecord,
  saveTaskInfo,
  removeTaskInfo,
  getAllTaskInfos,
  getTaskInfo,
  updateTaskState
} from './DownloadPersist';

export { OfflineMap } from './OfflineMap';

export { OfflineMapBridge } from './OfflineMapBridge';

export { ZipExtractor } from './ZipExtractor';
export type { ExtractProgressCallback } from './ZipExtractor';
