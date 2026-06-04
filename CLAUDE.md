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
- ⏳ MapPage / 瓦片渲染 — 待开发
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
│   │   ├── MapPage.ets
│   │   └── SettingsPage.ets
│   └── MainAbility/
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

## 开发须知
- 不能安装 DevEco Studio（Android Termux 环境），只能编辑代码
- 编译需要在有 HarmonyOS SDK 的 Windows/macOS 上
- Git 用 HTTPS，gh CLI 已认证

## 用户信息
- **GitHub 账号**: lovechengbao
- **手机环境**: Android Termux → PRoot Alpine Linux aarch64
- **开发设备**: Realme GT7 Pro (SM8750, Android 15, 6.6.66 GKI 内核, 已 root)
