/**
 * 下载任务持久化 — 使用 JSON 文件保存/恢复任务元数据
 *
 * 持久化文件位置: {context.filesDir}/harmonygis_downloads.json
 *
 * 关键设计：应用退出前暂停所有任务，持久化 taskId 和已下载字节数；
 * 重启后从持久化恢复，resume 时通过 HTTP Range 头实现断点续传。
 */

import fileIo from '@ohos.file.fs';
import { DownloadTaskInfo, DownloadState, PersistRecord } from './DownloadTypes';

const PERSIST_FILE = 'harmonygis_downloads.json';
const PERSIST_VERSION = 1;

/**
 * 从文件读取持久化记录
 */
export async function loadPersistRecord(filesDir: string): Promise<PersistRecord> {
  const filePath = filesDir + '/' + PERSIST_FILE;

  try {
    const stat: fileIo.Stat = fileIo.statSync(filePath);
    if (!stat.isFile()) {
      return createEmptyRecord();
    }
    const content: string = fileIo.readTextSync(filePath);
    if (!content || content.trim().length === 0) {
      return createEmptyRecord();
    }
    const record: PersistRecord = JSON.parse(content);
    // 版本校验
    if (record.version !== PERSIST_VERSION) {
      console.warn('[DownloadPersist] 持久化版本不匹配，使用空白记录');
      return createEmptyRecord();
    }
    return record;
  } catch (err) {
    console.warn('[DownloadPersist] 读取持久化文件失败，使用空白记录:', JSON.stringify(err));
    return createEmptyRecord();
  }
}

/**
 * 保存持久化记录到文件
 */
export function savePersistRecord(filesDir: string, record: PersistRecord): void {
  const filePath = filesDir + '/' + PERSIST_FILE;

  try {
    const content = JSON.stringify(record);
    const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.CREATE |
      fileIo.OpenMode.WRITE_ONLY |
      fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, content);
    fileIo.closeSync(file.fd);
  } catch (err) {
    console.error('[DownloadPersist] 保存持久化文件失败:', JSON.stringify(err));
  }
}

/**
 * 添加或更新单条任务记录
 */
export async function saveTaskInfo(filesDir: string, taskInfo: DownloadTaskInfo): Promise<void> {
  const record = await loadPersistRecord(filesDir);
  taskInfo.updateTime = Date.now();
  record.tasks[taskInfo.taskId] = taskInfo;
  savePersistRecord(filesDir, record);
}

/**
 * 删除单条任务记录
 */
export async function removeTaskInfo(filesDir: string, taskId: string): Promise<void> {
  const record = await loadPersistRecord(filesDir);
  if (record.tasks[taskId]) {
    // ArkTS 不支持 delete 运算符，用重建对象替代
    const newTasks: Record<string, DownloadTaskInfo> = {};
    const keys = Object.keys(record.tasks);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== taskId) {
        newTasks[keys[i]] = record.tasks[keys[i]];
      }
    }
    record.tasks = newTasks;
    savePersistRecord(filesDir, record);
  }
}

/**
 * 获取所有持久化的任务信息
 */
export async function getAllTaskInfos(filesDir: string): Promise<DownloadTaskInfo[]> {
  const record = await loadPersistRecord(filesDir);
  return Object.values(record.tasks);
}

/**
 * 获取单条任务信息
 */
export async function getTaskInfo(filesDir: string, taskId: string): Promise<DownloadTaskInfo | null> {
  const record = await loadPersistRecord(filesDir);
  return record.tasks[taskId] ?? null;
}

/**
 * 更新任务状态
 */
export async function updateTaskState(filesDir: string, taskId: string, state: DownloadState,
  downloadedBytes?: number, totalBytes?: number): Promise<void> {
  const record = await loadPersistRecord(filesDir);
  const task = record.tasks[taskId];
  if (task) {
    task.state = state;
    task.updateTime = Date.now();
    if (downloadedBytes !== undefined) {
      task.downloadedBytes = downloadedBytes;
    }
    if (totalBytes !== undefined) {
      task.totalBytes = totalBytes;
    }
    savePersistRecord(filesDir, record);
  }
}

// ── 内部工具 ────────────────────────────────────────────────

function createEmptyRecord(): PersistRecord {
  return {
    version: PERSIST_VERSION,
    tasks: {}
  };
}
