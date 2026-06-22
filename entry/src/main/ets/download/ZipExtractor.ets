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
   * @param targetDir 解压目标目录（不存在则自动创建，已存在则先清空再解压）
   * @param _onProgress 可选的进度回调（zlib.decompressFile 不支持逐文件回调，保留接口兼容）
   */
  static async extract(zipPath: string, targetDir: string,
    _onProgress?: ExtractProgressCallback): Promise<void> {
    console.info(`[ZipExtractor] 开始解压: ${zipPath} → ${targetDir}`);

    // 清理可能存在的旧解压目录（上次解压失败的残留 / 同名地图旧版本），
    // 防止 zlib.decompressFile 因目标目录已有文件而失败。
    if (fileIo.accessSync(targetDir)) {
      console.info(`[ZipExtractor] 清理旧目录: ${targetDir}`);
      await ZipExtractor.emptyDir(targetDir);
    }

    // 确保目标目录存在
    fileIo.mkdirSync(targetDir, true);

    // 使用系统内置 zlib.decompressFile（直接处理 ZIP 格式，含多文件+目录结构）
    await zlib.decompressFile(zipPath, targetDir);

    console.info(`[ZipExtractor] 解压完成: ${zipPath} → ${targetDir}`);
  }

  /**
   * 递归清空目录（API 11 无原生递归删除，手动遍历文件树）
   */
  private static async emptyDir(dirPath: string): Promise<void> {
    try {
      const entries = fileIo.listFileSync(dirPath);
      for (let i = 0; i < entries.length; i++) {
        const fullPath = dirPath + '/' + entries[i];
        try {
          const stat = fileIo.statSync(fullPath);
          if (stat.isDirectory()) {
            // ArkTS 不支持解构，用中间变量
            await ZipExtractor.emptyDir(fullPath);
            fileIo.rmdirSync(fullPath);
          } else {
            fileIo.unlinkSync(fullPath);
          }
        } catch (err) {
          console.warn(`[ZipExtractor] 删除文件失败，跳过: ${fullPath}, error=${JSON.stringify(err)}`);
        }
      }
    } catch (err) {
      // listFileSync 失败（可能不是目录），尝试直接删除
      console.warn(`[ZipExtractor] 遍历目录失败: ${dirPath}, error=${JSON.stringify(err)}`);
      try {
        fileIo.rmdirSync(dirPath);
      } catch (err2) {
        // 静默忽略
      }
    }
  }
}
