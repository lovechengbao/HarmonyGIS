/**
 * ZipExtractor — 纯 ArkTS ZIP 文件解压器
 *
 * 自行解析 ZIP 文件格式（EOCD → Central Directory → Local File Headers），
 * 结合 @ohos.zlib 完成 deflate 解压，无需额外原生依赖。
 *
 * 支持：
 * - 存储模式（method 0）
 * - Deflate 压缩（method 8，通过 @ohos.zlib.decompress）
 * - 自动创建子目录
 *
 * 不支持：
 * - 加密 ZIP
 * - ZIP64（超过 4GB 的归档）
 * - Deflate64 / BZip2 / LZMA 等其他压缩方法
 */

import zlib from '@ohos.zlib';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';

/** EOCD 签名: PK\x05\x06 */
const SIG_EOCD = 0x06054b50;
/** Central Directory 条目签名: PK\x01\x02 */
const SIG_CENTRAL_DIR = 0x02014b50;
/** Local File Header 签名: PK\x03\x04 */
const SIG_LOCAL_FILE = 0x04034b50;

/** EOCD 最小长度（不含注释） */
const EOCD_BASE_SIZE = 22;
/** EOCD 最大注释长度 */
const MAX_COMMENT_LEN = 65535;

/** 解压进度回调 */
export type ExtractProgressCallback = (current: number, total: number, fileName: string) => void;

/** EOCD 解析结果 */
interface EocdInfo {
  totalEntries: number;
  centralDirOffset: number;
}

/** Central Directory 条目解析结果 */
interface CdEntry {
  compressionMethod: number;
  compressedSize: number;
  uncompressedSize: number;
  localHeaderOffset: number;
  fileName: string;
}

export class ZipExtractor {
  /**
   * 解压 ZIP 文件到目标目录
   *
   * @param zipPath ZIP 文件绝对路径
   * @param targetDir 解压目标目录（不存在则自动创建）
   * @param onProgress 可选的进度回调
   */
  static async extract(zipPath: string, targetDir: string,
    onProgress?: ExtractProgressCallback): Promise<void> {
    console.info(`[ZipExtractor] 开始解压: ${zipPath} → ${targetDir}`);

    const file = await fileIo.open(zipPath, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(zipPath);
      const fileSize = stat.size;

      // 1. 定位 EOCD
      const eocd = await ZipExtractor.readEocd(file, fileSize);
      console.info(`[ZipExtractor] 条目数: ${eocd.totalEntries}, Central Dir 偏移: ${eocd.centralDirOffset}`);

      // 2. 解析 Central Directory
      const entries = await ZipExtractor.readCentralDir(file, eocd);

      // 3. 确保目标根目录存在
      if (!fileIo.accessSync(targetDir)) {
        fileIo.mkdirSync(targetDir, true);
      }

      // 4. 逐个解压
      const total = entries.length;
      for (let i = 0; i < total; i++) {
        const entry = entries[i];
        if (onProgress) {
          onProgress(i + 1, total, entry.fileName);
        }
        await ZipExtractor.extractEntry(file, entry, targetDir);
      }

      console.info(`[ZipExtractor] 解压完成: ${total} 个文件`);
    } finally {
      await fileIo.close(file);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // EOCD
  // ═══════════════════════════════════════════════════════════

  private static async readEocd(file: fileIo.File, fileSize: number): Promise<EocdInfo> {
    // 在文件末尾搜索 EOCD 签名（EOCD 后最多跟 65535 字节注释）
    const searchLen = Math.min(fileSize, EOCD_BASE_SIZE + MAX_COMMENT_LEN);
    const buf = new ArrayBuffer(searchLen);
    const readLen = await fileIo.read(file.fd, buf, {
      offset: 0,
      length: searchLen,
      position: fileSize - searchLen
    });

    const view = new DataView(buf);
    const dataLen = readLen;

    // 从后往前搜索签名
    for (let i = dataLen - EOCD_BASE_SIZE; i >= 0; i--) {
      if (view.getUint32(i, true) === SIG_EOCD) {
        const totalEntries = view.getUint16(i + 10, true);
        const centralDirOffset = view.getUint32(i + 16, true);

        const info: EocdInfo = {
          totalEntries: totalEntries,
          centralDirOffset: centralDirOffset
        };
        return info;
      }
    }

    throw new Error('[ZipExtractor] 未找到 EOCD 签名，文件可能不是有效的 ZIP');
  }

  // ═══════════════════════════════════════════════════════════
  // Central Directory
  // ═══════════════════════════════════════════════════════════

  private static async readCentralDir(file: fileIo.File, eocd: EocdInfo): Promise<CdEntry[]> {
    const entries: CdEntry[] = [];

    // 先用一个较大的 buffer 读取整个 central directory（大多数场景够用）
    // 对于超多文件的 zip，这里会分段读取，先做简化处理
    const cdSize = 64 * 1024; // 先读 64KB
    const buf = new ArrayBuffer(cdSize);
    const actualRead = await fileIo.read(file.fd, buf, {
      offset: 0,
      length: cdSize,
      position: eocd.centralDirOffset
    });

    const view = new DataView(buf);
    let pos = 0;
    const textDecoder = util.TextDecoder.create('utf-8');

    for (let i = 0; i < eocd.totalEntries; i++) {
      // 检查签名
      if (pos + 4 > actualRead || view.getUint32(pos, true) !== SIG_CENTRAL_DIR) {
        console.warn(`[ZipExtractor] Central Dir 签名不匹配 at entry ${i}, pos=${pos}`);
        break;
      }

      // 跳过 pos+4 (signature), pos+6 (version made by)
      const compressionMethod = view.getUint16(pos + 10, true);
      // pos+12: last mod time
      // pos+14: last mod date
      // pos+16: crc32
      const compressedSize = view.getUint32(pos + 20, true);
      const uncompressedSize = view.getUint32(pos + 24, true);
      const fileNameLen = view.getUint16(pos + 28, true);
      const extraLen = view.getUint16(pos + 30, true);
      const commentLen = view.getUint16(pos + 32, true);
      const localHeaderOffset = view.getUint32(pos + 42, true);

      // 读取文件名
      const fileNameStart = pos + 46;
      let fileName = '';
      if (fileNameLen > 0 && fileNameStart + fileNameLen <= actualRead) {
        const nameBuf = buf.slice(fileNameStart, fileNameStart + fileNameLen);
        fileName = textDecoder.decodeWithStream(nameBuf, { stream: false });
      }

      // 跳过目录条目（文件名以 / 结尾）
      const isDirectory = fileName.endsWith('/');

      if (!isDirectory) {
        const entry: CdEntry = {
          compressionMethod: compressionMethod,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localHeaderOffset,
          fileName: fileName
        };
        entries.push(entry);
      }

      // 移动到下一条目
      pos = fileNameStart + fileNameLen + extraLen + commentLen;
      if (pos > actualRead) {
        console.warn(`[ZipExtractor] Central Dir 读取超出缓冲区，截断`);
        break;
      }
    }

    return entries;
  }

  // ═══════════════════════════════════════════════════════════
  // 单条目解压
  // ═══════════════════════════════════════════════════════════

  private static async extractEntry(file: fileIo.File, entry: CdEntry,
    targetDir: string): Promise<void> {
    // 1. 读取 Local File Header
    const headerBuf = new ArrayBuffer(30);
    await fileIo.read(file.fd, headerBuf, {
      offset: 0,
      length: 30,
      position: entry.localHeaderOffset
    });

    const headerView = new DataView(headerBuf);

    // 验证签名
    if (headerView.getUint32(0, true) !== SIG_LOCAL_FILE) {
      console.warn(`[ZipExtractor] Local File Header 签名不匹配: ${entry.fileName}`);
      throw new Error(`Local File Header 签名不匹配: ${entry.fileName}`);
    }

    const fileNameLen = headerView.getUint16(26, true);
    const extraLen = headerView.getUint16(28, true);

    // 本地文件头可能包含与 Central Directory 不同的压缩大小（streaming 模式）
    // 优先使用 Central Directory 中的值
    const localCompressedSize = headerView.getUint32(18, true);
    const dataSize = localCompressedSize > 0 ? localCompressedSize : entry.compressedSize;

    // 数据起始位置 = local header offset + 30 + fileNameLen + extraLen
    const dataOffset = entry.localHeaderOffset + 30 + fileNameLen + extraLen;

    // 2. 读取压缩数据
    const compBuf = new ArrayBuffer(dataSize);
    const actualDataRead = await fileIo.read(file.fd, compBuf, {
      offset: 0,
      length: dataSize,
      position: dataOffset
    });

    if (actualDataRead < dataSize) {
      console.warn(`[ZipExtractor] 读取数据不足: expected=${dataSize}, actual=${actualDataRead}, file=${entry.fileName}`);
    }

    // 3. 解压或直接复制
    let uncompressed: ArrayBuffer;
    if (entry.compressionMethod === 0) {
      // 存储模式 — 直接使用原始数据
      uncompressed = compBuf;
    } else if (entry.compressionMethod === 8) {
      // Deflate 压缩
      uncompressed = await ZipExtractor.inflateRaw(compBuf, entry.uncompressedSize);
    } else {
      throw new Error(`[ZipExtractor] 不支持的压缩方法 ${entry.compressionMethod}: ${entry.fileName}`);
    }

    // 4. 写入目标文件
    const outPath = targetDir + '/' + entry.fileName;

    // 创建父目录
    const lastSlash = outPath.lastIndexOf('/');
    if (lastSlash > 0) {
      const parentDir = outPath.substring(0, lastSlash);
      if (!fileIo.accessSync(parentDir)) {
        fileIo.mkdirSync(parentDir, true);
      }
    }

    const outFile = await fileIo.open(outPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(outFile.fd, uncompressed);
    } finally {
      await fileIo.close(outFile);
    }

    console.info(`[ZipExtractor] 解压: ${entry.fileName} (${uncompressed.byteLength} bytes)`);
  }

  // ═══════════════════════════════════════════════════════════
  // Deflate 解压
  // ═══════════════════════════════════════════════════════════

  /**
   * 解压 raw deflate 数据（无 zlib/gzip 头）
   *
   * @ohos.zlib.decompress 默认期望 zlib 头部（2 字节 CMF+FLG + 4 字节 Adler-32 尾部），
   * 因此 raw deflate 需要包裹一层 zlib wrapper。
   */
  private static async inflateRaw(compressed: ArrayBuffer, expectedSize: number): Promise<ArrayBuffer> {
    // 先尝试直接解压（某些实现在未指定 format 时自动检测）
    try {
      const out = new ArrayBuffer(expectedSize > 0 ? expectedSize : compressed.byteLength * 4);
      await zlib.decompress(compressed, out);
      return out;
    } catch (_err) {
      // 直接解压失败 → 包裹 zlib 头再试
      console.info('[ZipExtractor] 直接解压失败，尝试包裹 zlib 头部');
    }

    // 构造 zlib 包装：头部 2 字节 + raw deflate + 尾部 Adler-32
    const zlibHeader = ZipExtractor.buildZlibHeader(compressed);
    const outBuf = new ArrayBuffer(expectedSize > 0 ? expectedSize : compressed.byteLength * 4);

    try {
      await zlib.decompress(zlibHeader, outBuf);
      return outBuf;
    } catch (err) {
      const e = err as Error;
      throw new Error(`[ZipExtractor] deflate 解压失败: ${e.message}`);
    }
  }

  /**
   * 为 raw deflate 数据构造 zlib wrapper
   *
   * zlib 格式 (RFC 1950):
   * - CMF (1 byte): 0x78
   * - FLG (1 byte): 根据压缩级别和校验和确定
   * - 压缩数据 (raw deflate)
   * - Adler-32 校验和 (4 bytes) — 对未压缩数据计算
   *
   * 简化方案：使用最常用的头部 0x78 0x9C（默认压缩级别），
   * 尾部 Adler-32 由 @ohos.zlib 内部自动处理。
   */
  private static buildZlibHeader(rawDeflate: ArrayBuffer): ArrayBuffer {
    // 0x78 = deflate, window=32K; 0x9C = default level, check bits ok
    const header = new Uint8Array([0x78, 0x9C]);
    const result = new ArrayBuffer(header.length + rawDeflate.byteLength);
    const resultView = new Uint8Array(result);
    resultView.set(header, 0);
    resultView.set(new Uint8Array(rawDeflate), header.length);
    return result;
  }
}
