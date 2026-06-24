/**
 * OfflineMapBridge — 离线地图 JS Bridge 对接层（全静态方法）
 *
 * 提供三个对 WebView JavaScript 暴露的方法，遵循统一模式：
 * (callbackId, ...业务参数) → 委托 OfflineMap → callback(callbackId, result)
 *
 * callback 由宿主 App 注入，内部通过 runJavaScript 将结果推回 WebView。
 *
 * 使用示例：
 *   await OfflineMapBridge.init(filesDir, filesDir + '/offlineMaps', (id, result) => {
 *     webview.runJavaScript(`CgsNativeBridge.onCallback('${id}', ${result})`);
 *   }, context.databaseDir + '/offlineMap');
 */

import { OfflineMap } from './OfflineMap';
import { DownloadManagerOptions } from './DownloadManager';
import { LocalTileHttpServer } from './LocalTileHttpServer';
import common from '@ohos.app.ability.common';

/**
 * JS 回调函数类型
 * @param callbackId JS 侧传入的回调标识，用于 runJavaScript 回传
 * @param result 状态码 / 进度值
 */
type JsCallback = (callbackId: string, result: number) => void;

/**
 * JS 字符串回调类型
 * @param callbackId JS 侧传入的回调标识
 * @param result 字符串结果（如 baseUrl）
 */
type JsStringCallback = (callbackId: string, result: string) => void;

export class OfflineMapBridge {
  private static callback: JsCallback;
  private static stringCallback: JsStringCallback;
  private static tileServer: LocalTileHttpServer | null = null;

  /**
   * 初始化 Bridge（必须在 JS 调用前执行）
   *
   * 内部自动初始化 OfflineMap（创建 DownloadManager 等），调用方无需感知底层细节。
   *
   * @param context 应用上下文（用于 SQLite 初始化）
   * @param filesDir 应用沙箱 filesDir（用于持久化下载记录）
   * @param saveDir 离线地图保存目录（绝对路径）
   * @param callback 宿主注入的回调函数（内部调用 WebView.runJavaScript）
   * @param extractRoot 解压目标根目录（如 databaseDir + '/offlineMap'），可选
   * @param options DownloadManager 可选配置（最大并发数等）
   */
  static async init(context: common.Context, filesDir: string, saveDir: string, callback: JsCallback,
    extractRoot?: string, options?: DownloadManagerOptions): Promise<void> {
    await OfflineMap.init(context, filesDir, saveDir, extractRoot, options);
    OfflineMapBridge.callback = callback;
    console.info('[OfflineMapBridge] 初始化完成');
  }

  /**
   * 启动或恢复地图下载
   *
   * 对应 JS 侧：CgsNativeBridge.getBridgeMethod('downloadMap')
   *
   * @param callbackId JS 回调标识
   * @param downloadurl 地图包下载地址
   * @param metadataUrl 元数据 XML 请求地址（下载前请求）
   * @param mapId 地图唯一标识
   * @param append 0=覆盖下载, 1=追加/恢复（目前暂未区分，统一走断点续传逻辑）
   */
  static async downloadMap(callbackId: string, downloadurl: string, metadataUrl: string, mapId: string,
    append: number): Promise<void> {
    const result: number = await OfflineMap.downloadMap(downloadurl, metadataUrl, mapId, 'offlineMap', true);
    OfflineMapBridge.callback(callbackId, result);
  }

  /**
   * 获取下载进度
   *
   * 对应 JS 侧：CgsNativeBridge.getBridgeMethod('getDownloadProgress')
   * JS 每 500ms 轮询一次
   *
   * @param callbackId JS 回调标识
   * @param mapId 地图唯一标识
   */
  static async getDownloadProgress(callbackId: string, mapId: string): Promise<void> {
    const percent: number = OfflineMap.getProgress(mapId);
    OfflineMapBridge.callback(callbackId, percent);
  }

  /**
   * 暂停地图下载
   *
   * 对应 JS 侧：CgsNativeBridge.getBridgeMethod('pauseDownloadingMap')
   * 暂停成功后 downloadMap 的 listener 会收到 -50
   *
   * @param callbackId JS 回调标识
   * @param mapId 地图唯一标识
   */
  static async pauseDownloadingMap(callbackId: string, mapId: string): Promise<void> {
    await OfflineMap.pauseDownloadingMap(mapId);
    OfflineMapBridge.callback(callbackId, 0);
  }

  // ═══════════════════════════════════════════════════════════════
  // 本地瓦片 HTTP 服务器
  // ═══════════════════════════════════════════════════════════════

  /**
   * 启动本地瓦片 HTTP 服务器
   *
   * @param tileRoot 3D Tiles 数据根目录
   * @param port     端口号，默认 8765
   */
  static async initTileServer(tileRoot: string, port: number = 8765): Promise<void> {
    if (OfflineMapBridge.tileServer) {
      console.warn('[OfflineMapBridge] 瓦片服务器已存在，先停止旧实例');
      await OfflineMapBridge.tileServer.stop();
    }
    OfflineMapBridge.tileServer = new LocalTileHttpServer(tileRoot, port);
    await OfflineMapBridge.tileServer.start();
    console.info('[OfflineMapBridge] 瓦片服务器已启动');
  }

  /**
   * 停止瓦片服务器（页面销毁时调用）
   */
  static async stopTileServer(): Promise<void> {
    if (OfflineMapBridge.tileServer) {
      await OfflineMapBridge.tileServer.stop();
      OfflineMapBridge.tileServer = null;
    }
  }

  /**
   * 注入字符串回调（用于将 baseUrl 推回 JS）
   */
  static setStringCallback(callback: JsStringCallback): void {
    OfflineMapBridge.stringCallback = callback;
  }

  /**
   * 获取本地瓦片基础 URL（JS 侧通过 Bridge 调用）
   *
   * 对应 JS 侧：CgsNativeBridge.getBridgeMethod('getTileBaseUrl')
   */
  static getTileBaseUrl(callbackId: string): void {
    let baseUrl = '';
    if (OfflineMapBridge.tileServer) {
      baseUrl = OfflineMapBridge.tileServer.getBaseUrl();
    }
    if (OfflineMapBridge.stringCallback) {
      OfflineMapBridge.stringCallback(callbackId, baseUrl);
    } else {
      console.error('[OfflineMapBridge] stringCallback 未注入，无法返回 baseUrl');
    }
    console.info('[OfflineMapBridge] getTileBaseUrl → ' + baseUrl);
  }
}
