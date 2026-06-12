/**
 * XmlFetcher — 地图元数据 XML 请求 + 解析器
 *
 * 使用 @ohos.net.http 发起非流式 GET 请求获取 XML 字符串，
 * 再用 @ohos.convertxml 解析为 JS Object。
 *
 * 全静态方法，无状态，直接调用。
 */

import http from '@ohos.net.http';
import convertxml from '@ohos.convertxml';

export class XmlFetcher {
  /**
   * 请求并解析 XML 元数据
   *
   * @param url 元数据 URL
   * @returns 解析后的 JS Object（失败时抛 Error）
   */
  static async fetchMetadata(url: string): Promise<Record<string, Object>> {
    console.info(`[XmlFetcher] 开始请求元数据: ${url}`);

    const httpRequest = http.createHttp();

    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000
      });

      const responseCode: number = response.responseCode;
      if (responseCode !== 200) {
        throw new Error(`HTTP ${responseCode}: 元数据请求失败`);
      }

      const xmlString: string = response.result as string;
      if (!xmlString || xmlString.trim().length === 0) {
        throw new Error('元数据响应为空');
      }

      console.info(`[XmlFetcher] 收到 XML 响应, 长度: ${xmlString.length}`);

      // 解析 XML → JS Object
      const converter = new convertxml.ConvertXML();
      const result: Record<string, Object> = converter.convertToJSObject(xmlString) as Record<string, Object>;

      console.info(`[XmlFetcher] XML 解析完成`);
      return result;
    } finally {
      httpRequest.destroy();
    }
  }
}
