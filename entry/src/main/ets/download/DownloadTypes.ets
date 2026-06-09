/**
 * 离线地图下载模块 — 类型定义
 */

/**
 * 下载任务状态
 */
export enum DownloadState {
  /** 等待中（队列中） */
  PENDING = 0,
  /** 下载中 */
  DOWNLOADING = 1,
  /** 已暂停 */
  PAUSED = 2,
  /** 已完成 */
  COMPLETED = 3,
  /** 失败 */
  FAILED = 4,
  /** 已取消 */
  CANCELLED = 5
}

/**
 * 下载任务配置（创建任务时传入）
 */
export interface DownloadConfig {
  /** 下载地址 */
  url: string;
  /** 保存目录（绝对路径） */
  saveDir: string;
  /** 文件名 */
  fileName: string;
  /** 自定义 HTTP 请求头 */
  headers?: Record<string, string>;
  /** 网络限制：0 = 任意, 1 = 仅 WiFi */
  networkType?: DownloadNetworkType;
  /** 最大重试次数（默认 3） */
  maxRetries?: number;
  /** 重试间隔毫秒（默认 5000） */
  retryDelay?: number;
  /** 任务描述/标签 */
  label?: string;
  /** 关联的元数据（如地图区域 ID、缩放级别等） */
  metadata?: Record<string, string>;
  /** 预指定 taskId（提供后跳过内部生成，允许调用方提前拿到 taskId） */
  taskId?: string;
}

/**
 * 网络类型限制
 */
export enum DownloadNetworkType {
  /** 任意网络 */
  ANY = 0,
  /** 仅 WiFi */
  WIFI = 1
}

/**
 * 下载进度快照
 */
export interface DownloadProgress {
  /** 任务唯一标识 */
  taskId: string;
  /** 当前状态 */
  state: DownloadState;
  /** 已下载字节数 */
  downloadedBytes: number;
  /** 总字节数（-1 表示未知） */
  totalBytes: number;
  /** 进度百分比 0-100 */
  progress: number;
  /** 最后一次更新时间戳 */
  updateTime: number;
}

/**
 * 持久化的任务元数据
 */
export interface DownloadTaskInfo {
  /** 任务唯一标识（应用层生成，持久化保存） */
  taskId: string;
  /** 下载地址 */
  url: string;
  /** 完整保存路径 */
  filePath: string;
  /** 已下载字节数（用于展示） */
  downloadedBytes: number;
  /** 总字节数 */
  totalBytes: number;
  /** 当前状态 */
  state: DownloadState;
  /** 标签 */
  label: string;
  /** 用户自定义元数据 */
  metadata: Record<string, string>;
  /** 自定义 HTTP 请求头（持久化存储，恢复时保留） */
  headers?: Record<string, string>;
  /** 网络限制：0 = 任意, 1 = 仅 WiFi */
  networkType?: DownloadNetworkType;
  /** 最大重试次数 */
  maxRetries?: number;
  /** 重试间隔毫秒 */
  retryDelay?: number;
  /** 创建时间戳 */
  createTime: number;
  /** 更新时间戳 */
  updateTime: number;
}

/**
 * 下载事件回调集合
 */
export interface DownloadCallbacks {
  /** 进度更新 */
  onProgress?: (progress: DownloadProgress) => void;
  /** 下载完成 */
  onCompleted?: (taskId: string, filePath: string) => void;
  /** 下载失败 */
  onFailed?: (taskId: string, error: string) => void;
  /** 已暂停 */
  onPaused?: (taskId: string) => void;
  /** 状态变化（含全部状态转换） */
  onStateChange?: (taskId: string, state: DownloadState) => void;
}

/**
 * 持久化记录集合
 */
export interface PersistRecord {
  version: number;
  tasks: Record<string, DownloadTaskInfo>;
}

/**
 * 任务事件类型
 */
export enum DownloadEvent {
  PROGRESS = 'progress',
  COMPLETED = 'completed',
  FAILED = 'failed',
  PAUSED = 'paused',
  REMOVED = 'removed'
}

/**
 * HTTP 流式下载进度事件数据（dataReceiveProgress 回调参数）
 */
export interface HttpProgressData {
  receiveSize: number;
  totalSize: number;
}
