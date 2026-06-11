/**
 * ZipExtractor — ZIP 文件解压器
 *
 * 基于 @ohos.zlib.decompressFile() 系统内置能力，无需手写 ZIP 格式解析。
 */

import zlib from '@ohos.zlib';
import fileIo from '@ohos.file.fs';

/** 解压进度回调 */
export type ExtractProgressCallback = (current: number, total: number, fileName: string) => void;

export class ZipExtractor {
  /**
   * 解压 ZIP 文件到目标目录
   *
   * @param zipPath ZIP 文件绝对路径
   * @param targetDir 解压目标目录（不存在则自动创建）
   * @param _onProgress 可选的进度回调（zlib.decompressFile 不支持逐文件回调，保留接口兼容）
   */
  static async extract(zipPath: string, targetDir: string,
    _onProgress?: ExtractProgressCallback): Promise<void> {
    console.info(`[ZipExtractor] 开始解压: ${zipPath} → ${targetDir}`);

    // 确保目标目录存在
    if (!fileIo.accessSync(targetDir)) {
      fileIo.mkdirSync(targetDir, true);
    }

    // 使用系统内置 zlib.decompressFile（直接处理 ZIP 格式，含多文件+目录结构）
    await zlib.decompressFile(zipPath, targetDir);

    console.info(`[ZipExtractor] 解压完成: ${zipPath} → ${targetDir}`);
  }
}
