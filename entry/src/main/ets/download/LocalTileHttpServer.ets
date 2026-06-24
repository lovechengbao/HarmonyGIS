/**
 * LocalTileHttpServer — 本地 HTTP 文件服务器（基于 TCP Socket）
 *
 * 在 127.0.0.1 上启动一个极简 HTTP 服务器，为 WebView 内的 JS 3D Tiles 库
 * 提供本地文件访问。对 Cesium / MapLibre 等 3D Tiles 库完全透明。
 *
 * 使用方式：
 *   const server = new LocalTileHttpServer('/storage/Users/currentUser/enc', 8765);
 *   await server.start();
 *   // JS 侧：fetch('http://127.0.0.1:8765/tileset.json')
 */

import socket from '@ohos.net.socket';
import fileIo from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

/** TCP 连接类型 */
type TcpClient = socket.TCPSocketConnection;

/** 解析后的 HTTP 请求 */
interface ParsedRequest {
  method: string;
  path: string;
}

export class LocalTileHttpServer {
  /** 瓦片文件根目录 */
  private tileRoot: string;
  /** 监听端口 */
  private port: number;
  /** 服务端实例 */
  private tcpServer: socket.TCPSocketServer | null = null;
  /** 活跃的客户端连接 */
  private clients: TcpClient[] = [];
  /** 是否正在运行 */
  private running: boolean = false;

  /**
   * @param tileRoot 3D Tiles 文件所在根目录，如 '/storage/Users/currentUser/enc'
   * @param port     监听端口，默认 8765
   */
  constructor(tileRoot: string, port: number = 8765) {
    this.tileRoot = tileRoot;
    this.port = port;
    if (!this.tileRoot.endsWith('/')) {
      this.tileRoot = this.tileRoot + '/';
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 公开方法
  // ═══════════════════════════════════════════════════════════

  /**
   * 启动 HTTP 服务器
   */
  async start(): Promise<void> {
    if (this.running) {
      console.warn('[TileServer] 已在运行中');
      return;
    }

    return new Promise<void>((resolve, reject) => {
      try {
        this.tcpServer = socket.constructTCPSocketServerInstance();

        this.tcpServer.listen({
          address: '127.0.0.1',
          port: this.port,
          family: 1
        }, (err: BusinessError) => {
          if (err) {
            console.error('[TileServer] 端口监听失败: code=' + String(err.code) + ' msg=' + err.message);
            reject(new Error('端口监听失败: ' + err.message));
            return;
          }
          this.running = true;
          console.info('[TileServer] ✅ 已启动 http://127.0.0.1:' + String(this.port));
          resolve();
        });

        this.tcpServer.on('connect', (client: TcpClient) => {
          this.handleClient(client);
        });

      } catch (err) {
        const e = err as BusinessError;
        reject(new Error('创建服务端失败: ' + e.message));
      }
    });
  }

  /**
   * 停止 HTTP 服务器，释放端口
   */
  async stop(): Promise<void> {
    this.running = false;

    for (let i = 0; i < this.clients.length; i++) {
      try {
        this.clients[i].close();
      } catch (_e) {
        // ignore
      }
    }
    this.clients = [];

    if (this.tcpServer) {
      try {
        this.tcpServer.off('connect');
        this.tcpServer.close();
      } catch (_e) {
        // ignore
      }
      this.tcpServer = null;
    }
    console.info('[TileServer] 已停止');
  }

  /**
   * 获取 JS 侧使用的基础 URL
   */
  getBaseUrl(): string {
    return 'http://127.0.0.1:' + String(this.port);
  }

  // ═══════════════════════════════════════════════════════════
  // TCP 客户端处理
  // ═══════════════════════════════════════════════════════════

  /**
   * 处理单个客户端连接
   */
  private handleClient(client: TcpClient): void {
    this.clients.push(client);
    let requestBuffer = '';

    client.on('message', (data: { message: ArrayBuffer; remoteInfo: object }) => {
      requestBuffer += this.bufToStr(data.message);

      const headerEnd = requestBuffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) {
        return;
      }

      const headerPart = requestBuffer.slice(0, headerEnd);
      const parsed = this.parseRequest(headerPart);

      console.info('[TileServer] ' + parsed.method + ' ' + parsed.path);

      const response = this.buildResponse(parsed);

      client.send({ data: response }, (err: BusinessError) => {
        if (err) {
          console.error('[TileServer] 发送失败: ' + err.message);
        }
        this.removeClient(client);
        try {
          client.close();
        } catch (_e) {
          // ignore
        }
      });
    });

    client.on('close', () => {
      this.removeClient(client);
    });

    client.on('error', (err: Error) => {
      console.warn('[TileServer] 连接异常: ' + err.message);
      this.removeClient(client);
    });
  }

  /**
   * 从活跃列表中移除客户端
   */
  private removeClient(client: TcpClient): void {
    const idx = this.clients.indexOf(client);
    if (idx >= 0) {
      this.clients.splice(idx, 1);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // HTTP 协议处理
  // ═══════════════════════════════════════════════════════════

  /**
   * 解析 HTTP 请求行
   */
  private parseRequest(headerBlock: string): ParsedRequest {
    const lines = headerBlock.split('\r\n');
    const requestLine = lines[0];
    const parts = requestLine.split(' ');

    const method = parts.length > 0 ? parts[0] : 'GET';
    let path = parts.length > 1 ? parts[1] : '/';

    const percentIndex = path.indexOf('%');
    if (percentIndex >= 0) {
      path = path.replace(/%20/g, ' ');
      path = path.replace(/%2F/g, '/');
    }

    const result: ParsedRequest = {
      method: method,
      path: path
    };
    return result;
  }

  /**
   * 根据 HTTP 请求构建响应
   */
  private buildResponse(request: ParsedRequest): ArrayBuffer {
    if (request.method !== 'GET') {
      return this.buildHttpResponse(405, 'Method Not Allowed', 'text/plain', this.strToBuf(''));
    }

    const relativePath = this.sanitizePath(request.path);
    if (relativePath === null) {
      return this.buildHttpResponse(403, 'Forbidden', 'text/plain',
        this.strToBuf('Access denied'));
    }

    if (relativePath.length === 0 || relativePath === '/') {
      return this.buildHttpResponse(200, 'OK', 'text/plain',
        this.strToBuf('LocalTileServer running. Root: ' + this.tileRoot));
    }

    const filePath = this.tileRoot + relativePath;

    try {
      const stat = fileIo.statSync(filePath);
      if (!stat.isFile()) {
        return this.buildHttpResponse(404, 'Not Found', 'text/plain',
          this.strToBuf('Not a file: ' + relativePath));
      }

      const fileSize = stat.size;
      const mimeType = this.getMimeType(filePath);
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);

      const buf = new ArrayBuffer(fileSize);
      const bytesRead = fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);

      const body = bytesRead < fileSize ? buf.slice(0, bytesRead) : buf;

      console.info('[TileServer] 200 ' + relativePath + ' (' + String(bytesRead) + ' bytes, ' + mimeType + ')');

      return this.buildHttpResponse(200, 'OK', mimeType, body);

    } catch (err) {
      const e = err as BusinessError;
      const errMsg = 'Read error [' + String(e.code) + ']: ' + e.message;
      return this.buildHttpResponse(500, 'Internal Server Error', 'text/plain',
        this.strToBuf(errMsg));
    }
  }

  /**
   * 安全检查：返回安全的相对路径，或 null（拒绝）
   */
  private sanitizePath(requestPath: string): string | null {
    const queryIdx = requestPath.indexOf('?');
    let cleanPath = queryIdx >= 0 ? requestPath.slice(0, queryIdx) : requestPath;

    if (cleanPath.length === 0 || cleanPath[0] !== '/') {
      cleanPath = '/' + cleanPath;
    }

    if (cleanPath.indexOf('..') >= 0) {
      console.warn('[TileServer] 路径穿越拒绝: ' + cleanPath);
      return null;
    }

    if (cleanPath[0] === '/') {
      cleanPath = cleanPath.slice(1);
    }

    return cleanPath;
  }

  /**
   * 构建完整 HTTP 响应
   */
  private buildHttpResponse(
    code: number,
    reason: string,
    contentType: string,
    body: ArrayBuffer
  ): ArrayBuffer {
    const bodyLen = body.byteLength;

    let header = 'HTTP/1.1 ' + String(code) + ' ' + reason + '\r\n';
    header += 'Content-Type: ' + contentType + '\r\n';
    header += 'Content-Length: ' + String(bodyLen) + '\r\n';
    header += 'Access-Control-Allow-Origin: *\r\n';
    header += 'Cache-Control: max-age=3600\r\n';
    header += 'Connection: close\r\n';
    header += 'Server: LocalTileServer/1.0\r\n';
    header += '\r\n';

    const headerBuf = this.strToBuf(header);
    const totalLen = headerBuf.byteLength + bodyLen;
    const fullBuf = new ArrayBuffer(totalLen);
    const fullView = new Uint8Array(fullBuf);

    const headerView = new Uint8Array(headerBuf);
    for (let i = 0; i < headerView.byteLength; i++) {
      fullView[i] = headerView[i];
    }

    const bodyView = new Uint8Array(body);
    for (let i = 0; i < bodyLen; i++) {
      fullView[headerBuf.byteLength + i] = bodyView[i];
    }

    return fullBuf;
  }

  // ═══════════════════════════════════════════════════════════
  // 工具方法
  // ═══════════════════════════════════════════════════════════

  /**
   * ArrayBuffer → 字符串（HTTP 头是纯 ASCII）
   */
  private bufToStr(buf: ArrayBuffer): string {
    const view = new Uint8Array(buf);
    let result = '';
    for (let i = 0; i < view.byteLength; i++) {
      result += String.fromCharCode(view[i]);
    }
    return result;
  }

  /**
   * 字符串 → ArrayBuffer（HTTP 头是纯 ASCII）
   */
  private strToBuf(str: string): ArrayBuffer {
    const buf = new ArrayBuffer(str.length);
    const view = new Uint8Array(buf);
    for (let i = 0; i < str.length; i++) {
      view[i] = str.charCodeAt(i) & 0xFF;
    }
    return buf;
  }

  /**
   * 根据文件扩展名返回 MIME 类型
   */
  private getMimeType(filePath: string): string {
    const dotIndex = filePath.lastIndexOf('.');
    if (dotIndex < 0) {
      return 'application/octet-stream';
    }
    const ext = filePath.slice(dotIndex).toLowerCase();

    if (ext === '.json') {
      return 'application/json';
    }
    if (ext === '.b3dm' || ext === '.i3dm' || ext === '.pnts' || ext === '.cmpt' || ext === '.bin') {
      return 'application/octet-stream';
    }
    if (ext === '.gltf') {
      return 'model/gltf+json';
    }
    if (ext === '.glb') {
      return 'model/gltf-binary';
    }
    if (ext === '.png') {
      return 'image/png';
    }
    if (ext === '.jpg' || ext === '.jpeg') {
      return 'image/jpeg';
    }
    if (ext === '.ktx2') {
      return 'image/ktx2';
    }
    if (ext === '.webp') {
      return 'image/webp';
    }
    if (ext === '.txt') {
      return 'text/plain';
    }
    if (ext === '.xml') {
      return 'application/xml';
    }

    return 'application/octet-stream';
  }
}
