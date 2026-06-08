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
 *   });
 */

import { OfflineMap } from './OfflineMap';
import { DownloadManagerOptions } from './DownloadManager';

/**
 * JS 回调函数类型
 * @param callbackId JS 侧传入的回调标识，用于 runJavaScript 回传
 * @param result 状态码 / 进度值
 */
type JsCallback = (callbackId: string, result: number) => void;

export class OfflineMapBridge {
  private static callback: JsCallback;

  /**
   * 初始化 Bridge（必须在 JS 调用前执行）
   *
   * 内部自动初始化 OfflineMap（创建 DownloadManager 等），调用方无需感知底层细节。
   *
   * @param filesDir 应用沙箱 filesDir（用于持久化下载记录）
   * @param saveDir 离线地图保存目录（绝对路径）
   * @param callback 宿主注入的回调函数（内部调用 WebView.runJavaScript）
   * @param options DownloadManager 可选配置（最大并发数等）
   */
  static async init(filesDir: string, saveDir: string, callback: JsCallback, options?: DownloadManagerOptions): Promise<void> {
    await OfflineMap.init(filesDir, saveDir, options);
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
   * @param mapId 地图唯一标识
   * @param append 0=覆盖下载, 1=追加/恢复（目前暂未区分，统一走断点续传逻辑）
   */
  static async downloadMap(callbackId: string, downloadurl: string, mapId: string, append: number): Promise<void> {
    const result: number = await OfflineMap.downloadMap(downloadurl, mapId, 'offlineMap', true);
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
}
