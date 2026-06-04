package com.example;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.io.File;
import java.io.RandomAccessFile;
import java.nio.file.Path;

@SpringBootApplication
@RestController
public class TestServerApplication {

    /** 测试文件存储目录 */
    private static final Path STORAGE = Path.of(System.getProperty("user.dir"), "test-files");
    /** 默认测试文件大小：500MB */
    private static final long DEFAULT_FILE_SIZE = 500 * 1024 * 1024;

    public static void main(String[] args) {
        ensureTestFile("test.bin", DEFAULT_FILE_SIZE);
        ensureTestFile("test_1k.bin", 1024);
        SpringApplication.run(TestServerApplication.class, args);
    }

    // ═══════════════════════════════════════════════════════════════
    // 下载接口
    // ═══════════════════════════════════════════════════════════════

    /**
     * 下载文件（支持 Range 断点续传）
     *
     * 测试示例：
     *   curl -v http://localhost:8080/download/test.bin
     *   curl -v -H "Range: bytes=0-1023" http://localhost:8080/download/test.bin
     *   curl -v -H "Range: bytes=1024-" http://localhost:8080/download/test.bin
     *   curl -v -C - -o test.bin http://localhost:8080/download/test.bin
     */
    @GetMapping("/download/{filename}")
    public ResponseEntity<Resource> download(
            @PathVariable String filename,
            HttpServletRequest request) {

        File file = STORAGE.resolve(filename).toFile();

        if (!file.exists() || !file.isFile()) {
            return listFiles();
        }

        long fileLength = file.length();
        String rangeHeader = request.getHeader(HttpHeaders.RANGE);

        // 无 Range 头 → 完整下载
        if (rangeHeader == null || !rangeHeader.startsWith("bytes=")) {
            Resource body = new FileSystemResource(file);
            return ResponseEntity.ok()
                    .contentType(MediaType.APPLICATION_OCTET_STREAM)
                    .header(HttpHeaders.ACCEPT_RANGES, "bytes")
                    .contentLength(fileLength)
                    .body(body);
        }

        // 有 Range 头 → 部分内容
        return handleRangeRequest(file, fileLength, rangeHeader);
    }

    /**
     * HEAD /download/{filename} — 获取文件元信息（不下载内容）
     */
    @RequestMapping(value = "/download/{filename}", method = RequestMethod.HEAD)
    public ResponseEntity<Void> head(@PathVariable String filename) {
        File file = STORAGE.resolve(filename).toFile();
        if (!file.exists()) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .header(HttpHeaders.ACCEPT_RANGES, "bytes")
                .contentLength(file.length())
                .build();
    }

    /**
     * GET / — 列出所有可下载的文件
     */
    @GetMapping("/")
    public ResponseEntity<Resource> listFiles() {
        File[] files = STORAGE.toFile().listFiles();
        StringBuilder html = new StringBuilder();
        html.append("""
                <!DOCTYPE html>
                <html>
                <head><meta charset="utf-8"><title>断点续传测试</title></head>
                <body>
                <h2>📥 断点续传测试服务器</h2>
                <p>支持 HTTP Range 请求 | <code>Accept-Ranges: bytes</code></p>
                <hr>
                <h3>可用文件：</h3>
                <ul>
                """);

        if (files != null) {
            for (File f : files) {
                if (f.isFile()) {
                    html.append("<li><a href='/download/").append(f.getName()).append("'>")
                        .append(f.getName()).append("</a> (")
                        .append(formatSize(f.length())).append(")</li>\n");
                }
            }
        }

        html.append("""
                </ul>
                <hr>
                <h3>测试命令：</h3>
                <pre>
                # 完整下载
                curl -v http://localhost:8080/download/test.bin -o test.bin

                # 断点续传（从 1024 字节处继续）
                curl -v -H "Range: bytes=1024-" http://localhost:8080/download/test.bin -o partial.bin

                # 下载前 1KB
                curl -v -H "Range: bytes=0-1023" http://localhost:8080/download/test.bin -o first_1k.bin

                # 模拟断点续传（先下 1KB，中断，再续传）
                curl -H "Range: bytes=0-1023" http://localhost:8080/download/test.bin -o chunk.bin
                curl -H "Range: bytes=1024-" http://localhost:8080/download/test.bin -o chunk.bin --append
                </pre>
                </body>
                </html>""");

        return ResponseEntity.ok()
                .contentType(MediaType.TEXT_HTML)
                .header(HttpHeaders.CONTENT_TYPE, "text/html; charset=utf-8")
                .build();
    }

    // ═══════════════════════════════════════════════════════════════
    // Range 请求处理
    // ═══════════════════════════════════════════════════════════════

    /**
     * 解析 Range 头并返回 206 Partial Content
     *
     * 支持格式：
     *   bytes=N-M    → 指定范围的字节
     *   bytes=N-     → 从 N 到文件末尾
     *   bytes=-M     → 最后 M 个字节
     */
    private ResponseEntity<Resource> handleRangeRequest(File file, long fileLength, String rangeHeader) {
        // 去掉 "bytes=" 前缀
        String rangeValue = rangeHeader.substring(6).trim();
        String[] parts = rangeValue.split(",")[0].trim().split("-");   // 只处理第一个 range

        long start;
        long end;

        try {
            if (rangeValue.startsWith("-")) {
                // bytes=-500  → 最后 500 字节
                end = fileLength - 1;
                start = fileLength - Long.parseLong(parts[1]);
                if (start < 0) start = 0;
            } else if (rangeValue.endsWith("-")) {
                // bytes=1024-  → 从 1024 到末尾
                start = Long.parseLong(parts[0]);
                end = fileLength - 1;
            } else {
                // bytes=0-1023 → 指定范围
                start = Long.parseLong(parts[0]);
                end = Long.parseLong(parts[1]);
            }
        } catch (NumberFormatException e) {
            return ResponseEntity.status(HttpStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    .header(HttpHeaders.CONTENT_RANGE, "bytes */" + fileLength)
                    .build();
        }

        // 范围校验
        if (start >= fileLength || end >= fileLength || start > end) {
            return ResponseEntity.status(HttpStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    .header(HttpHeaders.CONTENT_RANGE, "bytes */" + fileLength)
                    .build();
        }

        long contentLength = end - start + 1;

        // 读取指定范围的内容
        byte[] data = new byte[(int) contentLength];
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            raf.seek(start);
            raf.readFully(data);
        } catch (Exception e) {
            return ResponseEntity.internalServerError().build();
        }

        String contentRange = String.format("bytes %d-%d/%d", start, end, fileLength);

        System.out.printf("[Range] %s → %d-%d/%d (%d bytes)%n",
                rangeHeader, start, end, fileLength, contentLength);

        return ResponseEntity.status(HttpStatus.PARTIAL_CONTENT)
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .header(HttpHeaders.ACCEPT_RANGES, "bytes")
                .header(HttpHeaders.CONTENT_RANGE, contentRange)
                .contentLength(contentLength)
                .body(new org.springframework.core.io.ByteArrayResource(data));
    }

    // ═══════════════════════════════════════════════════════════════
    // 测试文件生成
    // ═══════════════════════════════════════════════════════════════

    /**
     * 生成可预测内容的测试文件（每字节 = 偏移量 % 256，方便验证完整性）
     */
    private static void ensureTestFile(String name, long size) {
        File file = STORAGE.resolve(name).toFile();
        STORAGE.toFile().mkdirs();

        if (file.exists() && file.length() == size) {
            System.out.println("✅ 测试文件已存在: " + name + " (" + formatSize(size) + ")");
            return;
        }

        System.out.println("🔧 生成测试文件: " + name + " (" + formatSize(size) + ") ...");
        try (java.io.FileOutputStream fos = new java.io.FileOutputStream(file)) {
            byte[] buf = new byte[65536]; // 64KB buffer
            long remaining = size;
            long offset = 0;

            while (remaining > 0) {
                int chunk = (int) Math.min(remaining, buf.length);
                // 填充可验证的内容：每个字节 = 偏移量 % 256
                for (int i = 0; i < chunk; i++) {
                    buf[i] = (byte) ((offset + i) & 0xFF);
                }
                fos.write(buf, 0, chunk);
                offset += chunk;
                remaining -= chunk;
            }
        } catch (Exception e) {
            System.err.println("❌ 生成测试文件失败: " + e.getMessage());
        }
        System.out.println("✅ 测试文件已生成: " + name + " (" + formatSize(size) + ")");
    }

    private static String formatSize(long bytes) {
        if (bytes < 1024) return bytes + " B";
        if (bytes < 1024 * 1024) return String.format("%.1f KB", bytes / 1024.0);
        if (bytes < 1024 * 1024 * 1024) return String.format("%.1f MB", bytes / (1024.0 * 1024.0));
        return String.format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0));
    }
}
