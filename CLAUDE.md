# CLAUDE.md — HarmonyGIS 项目记忆

## 项目概述
- **HarmonyGIS**: 基于 OpenHarmony API 11 的 GIS 应用
- **技术栈**: ArkTS + ArkUI（声明式 UI）+ Hvigor 构建
- **GitHub 仓库**: https://github.com/lovechengbao/HarmonyGIS.git
- **许可证**: MIT
- **仓库可见性**: 私有

## 当前状态
- ✅ 离线地图下载模块已完成（entry/src/main/ets/download/）
  - DownloadManager — 多任务管理器（并发/排队/全局进度）
  - DownloadTask — 单任务（HTTP Range 断点续传/失败重试/异步 I/O）
  - HttpResumeDownloader — 轻量单文件下载器
  - DownloadPersist — JSON 持久化层（跨会话恢复）
  - DownloadTypes — 类型定义
- ✅ MapPage — 下载管理测试界面（添加任务/进度条/暂停/恢复/取消）
- ✅ 断点续传测试服务器 — Spring Boot 3.2（test-server/）
- ⏳ 地图瓦片渲染 — 待开发
- ⏳ 离线地图包解析 — 待开发

## 项目结构
```
HarmonyGIS/
├── entry/src/main/ets/
│   ├── download/              ← 离线地图下载模块
│   │   ├── DownloadManager.ets
│   │   ├── DownloadTask.ets
│   │   ├── HttpResumeDownloader.ets
│   │   ├── DownloadPersist.ets
│   │   ├── DownloadTypes.ets
│   │   └── index.ets
│   ├── pages/                 ← UI 页面
│   │   ├── MapPage.ets        ← 下载管理测试界面
│   │   └── SettingsPage.ets
│   └── MainAbility/
├── test-server/               ← Spring Boot 断点续传测试服务器
│   ├── pom.xml
│   └── src/main/java/com/example/TestServerApplication.java
├── AppScope/
├── hvigor/
├── build-profile.json5
└── oh-package.json5
```

## API 11 开发约束（必须遵守）
1. **导入只能用 @ohos.***，不能用 @kit.***（API 12+ 才有）
2. **HTTP 流式下载用 requestInStream()**，不是 request()（后者限 5MB）
3. **进度事件是 dataReceiveProgress**，不是 dataProgress
4. **没有 dataError 事件**，错误走 requestInStream().catch()
5. **ArkTS 不允许内联对象字面量作为类型声明** — 必须定义命名接口
6. **ArkTS 不支持 delete 运算符** — 用对象重建替代
7. **文件 I/O 用异步版本**（open/write/close），避免主线程阻塞
8. **API 11 的 @ohos.file.fs 同步 API 可能返回 Promise** — 全部走 async/await
9. **@ohos.net.http 和 @ohos.file.fs 必须用默认导入**，不能用命名导入
   - ✅ `import http from '@ohos.net.http'`
   - ✅ `import fileIo from '@ohos.file.fs'`
   - ❌ `import { http } from '@ohos.net.http'`
   - ❌ `import { fileIo } from '@ohos.file.fs'`
10. **ArkTS 不支持解构声明** — Map 遍历用 `forEach` 替代 `for (const [k,v] of map)`
11. **ArkTS 禁止 call signature 接口** — 回调类型用 `type` 别名
    - ✅ `type ResumeProgressCallback = (downloaded: number, total: number) => void`
    - ❌ `interface ResumeProgressCallback { (downloaded: number, total: number): void }`
12. **ArkTS throw 只能用 Error 实例** — `throw new Error(...)` 不能 `throw err`

## 下载模块架构要点

### 关键设计模式：避免 UI 阻塞
- `DownloadTask.initTaskId()` — 同步生成 taskId，不启动下载
- `DownloadTask.startDownload()` — 异步启动下载，**不阻塞调用者**
- `DownloadManager.createTask()` — 立即返回 taskId，下载在后台异步进行
- **核心原则**：创建/暂停/恢复操作都不要 `await` 整个下载过程

### 暂停的正确流程
```
用户点击暂停 → task.pause()
  1. this.stopped = true        ← 禁止重试
  2. clearRetryTimer()           ← 取消待处理的重试定时器
  3. setState(PAUSED)            ← 先改状态（非先断连，防止竞态）
  4. destroyHttpRequest()        ← 断 HTTP 连接
  5. closeFile()                 ← 排空 writeQueue 后关文件
```
- **关键**：先设 `stopped=true` 再改状态再断连，顺序不能变
- dataReceive / dataEnd / requestInStream.catch 三个处理器都要检查 `this.stopped`
- handleFailure / retryResume 检查 stopped + PAUSED 状态，两者任一为真就跳过

### 断点续传
- 暂停后 `downloadedBytes` 保留，恢复时 `resume()` 调用 `startHttpDownload(downloadedBytes)`
- `startHttpDownload` 内部设 `Range: bytes={downloadedBytes}-` 请求头
- 文件以 APPEND 模式打开（不截断已有数据）

### 已知的 ArkUI 渲染问题
- `ForEach` 在 ArkTS API 11 中可能不随 @State 自动重渲染单项
- 解决方法：**key 里包含会变化的值**（如 `'task_' + id + '_' + state`），状态变化时 key 变了就会强制重渲染

## 测试服务器（test-server/）
- **启动**：`cd test-server && mvn spring-boot:run`
- **端口**：8080（需 Windows 防火墙放行）
- **测试文件**：启动时自动生成 `test_1k.bin`(1KB) 和 `test.bin`(500MB)
- **Range 支持**：`curl -H "Range: bytes=N-M" http://localhost:8080/download/test.bin`
- **模拟器访问宿主机**：使用 `10.0.2.2` 替代 `localhost`

## 开发须知
- 不能安装 DevEco Studio（Android Termux 环境），只能编辑代码
- 编译需要在有 HarmonyOS SDK 的 Windows/macOS 上
- Git 用 HTTPS，gh CLI 已认证
- Windows 连不上 GitHub 时设代理：`git config --global http.proxy http://127.0.0.1:7897`

## 用户信息
- **GitHub 账号**: lovechengbao
- **手机环境**: Android Termux → PRoot Alpine Linux aarch64
- **开发设备**: Realme GT7 Pro (SM8750, Android 15, 6.6.66 GKI 内核, 已 root)
