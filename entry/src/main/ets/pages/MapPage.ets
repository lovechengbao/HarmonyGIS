/**
 * MapPage - 下载管理器测试页面
 *
 * 提供完整的下载测试功能：添加任务、查看进度、暂停/恢复/取消
 */

import common from '@ohos.app.ability.common';
import fileIo from '@ohos.file.fs';
import promptAction from '@ohos.promptAction';
import { DownloadManager, DownloadState } from '../download/index';
import { DownloadProgress } from '../download/DownloadTypes';
import { DownloadSummary } from '../download/DownloadManager';

/** 单条任务展示数据 */
interface TaskDisplayItem {
  taskId: string;
  label: string;
  state: DownloadState;
  progress: number;
  downloadedBytes: number;
  totalBytes: number;
  stateText: string;
  stateColor: string;
}

/** 状态文本+颜色 */
interface StateDisplayInfo {
  text: string;
  color: string;
}

@Entry
@Component
struct MapPage {
  @State displayItems: TaskDisplayItem[] = [];
  @State overallProgress: number = 0;
  @State runningCount: number = 0;
  @State completedCount: number = 0;
  @State failedCount: number = 0;
  @State totalTasks: number = 0;
  @State urlInput: string = 'http://10.0.2.2:8080/download/test.bin';
  @State fileNameInput: string = 'test_50m.bin';
  @State isInitialized: boolean = false;
  @State statusText: string = '初始化中...';

  private manager: DownloadManager | null = null;
  private taskLabels: Map<string, string> = new Map();
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    this.initManager();
    // 兜底：每秒强制刷新 UI
    this.refreshTimer = setInterval(() => {
      this.syncDisplayItems();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.manager) {
      this.manager.onDestroy();
    }
  }

  private async initManager(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.manager = new DownloadManager(ctx.filesDir, { maxConcurrency: 3 });

      await this.manager.initialize({
        onGlobalProgress: (_all: DownloadProgress[], sum: DownloadSummary) => {
          console.info(`[MapPage] onGlobalProgress: tasks=${sum.totalTasks}, active=${sum.activeTasks}, progress=${sum.overallProgress}%`);
          this.overallProgress = sum.overallProgress;
          this.runningCount = sum.activeTasks;
          this.completedCount = sum.completedTasks;
          this.failedCount = sum.failedTasks;
          this.totalTasks = sum.totalTasks;
          // 同步更新每条任务的进度
          this.syncDisplayItems();
        },
        onTaskCompleted: (_taskId: string, _filePath: string) => {
          this.refreshDisplayItems();
          this.showToast('下载完成');
        },
        onTaskFailed: (_taskId: string, error: string) => {
          this.refreshDisplayItems();
          this.showToast(`下载失败: ${error}`);
        },
        onTaskStateChange: (_taskId: string, _state: DownloadState) => {
          this.refreshDisplayItems();
        }
      });

      // 初始化完成后，从持久化加载任务标签
      await this.loadTaskLabels();
      this.syncDisplayItems();
      this.isInitialized = true;
      this.statusText = '就绪';
    } catch (err) {
      this.statusText = '初始化失败';
      console.error('[MapPage] 初始化失败:', JSON.stringify(err));
    }
  }

  /**
   * 同步显示列表（基于内存中的实时进度，轻量刷新）
   */
  private syncDisplayItems(): void {
    if (!this.manager) {
      return;
    }

    const progressList = this.manager.getAllProgress();
    const items: TaskDisplayItem[] = [];

    for (const p of progressList) {
      console.info(`[MapPage] syncDisplayItems: taskId=${p.taskId}, state=${p.state}, progress=${p.progress}%, downloaded=${p.downloadedBytes}, total=${p.totalBytes}`);
      items.push(this.buildDisplayItem(p.taskId, p.state, p.progress, p.downloadedBytes, p.totalBytes));
    }

    console.info(`[MapPage] syncDisplayItems: 共 ${items.length} 条任务`);
    this.displayItems = items;
  }

  /**
   * 刷新显示列表（从持久化加载完整信息，较重）
   */
  private async refreshDisplayItems(): Promise<void> {
    if (!this.manager) {
      return;
    }

    await this.loadTaskLabels();
    this.syncDisplayItems();
  }

  /**
   * 从持久化加载所有任务的 label
   */
  private async loadTaskLabels(): Promise<void> {
    if (!this.manager) {
      return;
    }

    try {
      const taskList = await this.manager.getTaskList();
      const newMap = new Map<string, string>();

      for (const info of taskList) {
        const displayLabel = info.label || info.url || info.taskId;
        newMap.set(info.taskId, displayLabel);
      }

      this.taskLabels = newMap;
    } catch (err) {
      console.error('[MapPage] 加载任务标签失败:', JSON.stringify(err));
    }
  }

  /**
   * 构建单条展示数据
   */
  private buildDisplayItem(
    taskId: string,
    state: DownloadState,
    progress: number,
    downloadedBytes: number,
    totalBytes: number
  ): TaskDisplayItem {
    const stateInfo = this.getStateInfo(state);

    return {
      taskId: taskId,
      label: this.taskLabels.get(taskId) || taskId,
      state: state,
      progress: progress,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      stateText: stateInfo.text,
      stateColor: stateInfo.color
    };
  }

  /**
   * 获取状态文本和颜色
   */
  private getStateInfo(state: DownloadState): StateDisplayInfo {
    switch (state) {
      case DownloadState.PENDING: {
        const info: StateDisplayInfo = { text: '等待中', color: '#909399' };
        return info;
      }
      case DownloadState.DOWNLOADING: {
        const info: StateDisplayInfo = { text: '下载中', color: '#409EFF' };
        return info;
      }
      case DownloadState.PAUSED: {
        const info: StateDisplayInfo = { text: '已暂停', color: '#E6A23C' };
        return info;
      }
      case DownloadState.COMPLETED: {
        const info: StateDisplayInfo = { text: '已完成', color: '#67C23A' };
        return info;
      }
      case DownloadState.FAILED: {
        const info: StateDisplayInfo = { text: '失败', color: '#F56C6C' };
        return info;
      }
      case DownloadState.CANCELLED: {
        const info: StateDisplayInfo = { text: '已取消', color: '#C0C4CC' };
        return info;
      }
      default: {
        const info: StateDisplayInfo = { text: '未知', color: '#909399' };
        return info;
      }
    }
  }

  /**
   * 格式化字节数为可读字符串
   */
  private formatBytes(bytes: number): string {
    if (bytes <= 0) {
      return '--';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  /**
   * 显示 Toast 提示
   */
  private showToast(message: string): void {
    promptAction.showToast({
      message: message,
      duration: 2000
    });
  }

  // ═══════════════════════════════════════════════════════════
  // 操作
  // ═══════════════════════════════════════════════════════════

  private async addDownload(): Promise<void> {
    const url = this.urlInput.trim();
    const fileName = this.fileNameInput.trim();

    if (!url) {
      this.showToast('请输入下载地址');
      return;
    }
    if (!fileName) {
      this.showToast('请输入文件名');
      return;
    }
    if (!this.manager) {
      this.showToast('管理器未初始化');
      return;
    }

    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const saveDir = ctx.filesDir + '/downloads';

      // 确保下载目录存在
      if (!fileIo.accessSync(saveDir)) {
        fileIo.mkdirSync(saveDir, true);
      }

      const taskId = await this.manager.createTask({
        url: url,
        saveDir: saveDir,
        fileName: fileName,
        label: fileName
      });

      this.showToast(`任务已创建: ${taskId.slice(0, 8)}...`);
      this.fileNameInput = '';
      await this.refreshDisplayItems();
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : JSON.stringify(err);
      this.showToast(`创建失败: ${errMsg}`);
      console.error('[MapPage] 创建任务失败:', errMsg);
    }
  }

  private async pauseTask(taskId: string): Promise<void> {
    if (!this.manager) {
      return;
    }
    await this.manager.pauseTask(taskId);
    this.syncDisplayItems();
  }

  private async resumeTask(taskId: string): Promise<void> {
    if (!this.manager) {
      return;
    }
    await this.manager.resumeTask(taskId);
    this.syncDisplayItems();
  }

  private async cancelTask(taskId: string): Promise<void> {
    if (!this.manager) {
      return;
    }
    await this.manager.cancelTask(taskId, true);
    this.taskLabels.delete(taskId);
    await this.refreshDisplayItems();
    this.showToast('任务已取消');
  }

  private async pauseAll(): Promise<void> {
    if (!this.manager) {
      return;
    }
    await this.manager.pauseAll();
    this.syncDisplayItems();
    this.showToast('已暂停全部');
  }

  private async resumeAll(): Promise<void> {
    if (!this.manager) {
      return;
    }
    await this.manager.resumeAll();
    this.syncDisplayItems();
    this.showToast('已恢复全部');
  }

  // ═══════════════════════════════════════════════════════════
  // UI 构建
  // ═══════════════════════════════════════════════════════════

  build() {
    Column() {
      // ── 顶栏 ──────────────────────────────────────────
      Row() {
        Text('HarmonyGIS — 下载管理')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1);

        Text(this.statusText)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .opacity(0.8);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#303133');

      // ── 全局进度条 ─────────────────────────────────────
      Row() {
        Progress({
          value: this.overallProgress,
          total: 100,
          type: ProgressType.Linear
        })
          .width('100%')
          .height(4)
          .color('#409EFF')
          .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor('#F0F2F5');

      // ── 全局统计 ──────────────────────────────────────
      Row() {
        Text(this.overallProgress > 0
          ? `总进度 ${this.overallProgress}%`
          : '下载中...')
          .fontSize(13)
          .fontColor('#303133')
          .fontWeight(FontWeight.Medium);

        Blank();

        Text(`活跃 ${this.runningCount}`)
          .fontSize(12)
          .fontColor('#409EFF')
          .margin({ left: 12 });

        Text(`完成 ${this.completedCount}`)
          .fontSize(12)
          .fontColor('#67C23A')
          .margin({ left: 12 });

        Text(`失败 ${this.failedCount}`)
          .fontSize(12)
          .fontColor('#F56C6C')
          .margin({ left: 12 });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF');

      Divider().height(1).color('#E4E7ED');

      // ── 添加下载区域 ──────────────────────────────────
      Column() {
        Text('新建下载')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#303133')
          .margin({ bottom: 8 });

        TextInput({ placeholder: '输入下载 URL', text: this.urlInput })
          .width('100%')
          .height(40)
          .fontSize(13)
          .backgroundColor('#F5F7FA')
          .borderRadius(6)
          .onChange((value: string) => {
            this.urlInput = value;
          });

        Row() {
          TextInput({ placeholder: '文件名（如 tile.png）', text: this.fileNameInput })
            .height(40)
            .fontSize(13)
            .backgroundColor('#F5F7FA')
            .borderRadius(6)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.fileNameInput = value;
            });

          Button('添加下载')
            .fontSize(13)
            .height(40)
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .backgroundColor('#409EFF')
            .borderRadius(6)
            .onClick(() => {
              this.addDownload();
            });
        }
        .width('100%')
        .margin({ top: 8 });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF');

      Divider().height(1).color('#E4E7ED');

      // ── 任务列表（直接渲染，不用 ForEach 避免兼容问题）──────────────────
      if (this.displayItems.length > 0) {
        Text('任务列表 (' + this.displayItems.length + '条)').fontSize(12).fontColor('#909399').margin({ left: 12, top: 8 });
      }
      if (this.displayItems.length === 0) {
        Text('暂无下载任务')
          .fontSize(14).fontColor('#C0C4CC').margin({ top: 60 });
      }
      if (this.displayItems.length > 0) {
        Scroll() {
          Column() {
            ForEach(this.displayItems, (item: TaskDisplayItem, index: number) => {
              Column() {
                Row() {
                  Text(item.label)
                    .fontSize(13).fontColor('#303133').fontWeight(FontWeight.Medium)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
                  Text(item.stateText)
                    .fontSize(11).fontColor(item.stateColor)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor(item.stateColor + '20').borderRadius(4);
                }
                .width('100%');

                Progress({ value: item.progress, total: 100, type: ProgressType.Linear })
                  .width('100%').height(6)
                  .color(this.getProgressColor(item.state))
                  .margin({ top: 8, bottom: 4 });

                Row() {
                  Text(item.totalBytes > 0 ? `${item.progress}%` : `已下载 ${this.formatBytes(item.downloadedBytes)}`)
                    .fontSize(12).fontColor('#909399');
                  Blank();
                  Text(item.totalBytes > 0
                    ? `${this.formatBytes(item.downloadedBytes)} / ${this.formatBytes(item.totalBytes)}`
                    : `${this.formatBytes(item.downloadedBytes)} / 未知`)
                    .fontSize(11).fontColor('#C0C4CC');
                }
                .width('100%');

                if (item.state === DownloadState.DOWNLOADING || item.state === DownloadState.PENDING) {
                  Row() {
                    Button('暂停').fontSize(11).height(28).padding({ left: 12, right: 12 })
                      .backgroundColor('#E6A23C').borderRadius(4)
                      .onClick(() => { console.info('[MapPage] 点击暂停'); this.pauseTask(item.taskId); });
                    Button('取消').fontSize(11).height(28).padding({ left: 12, right: 12 })
                      .backgroundColor('#F56C6C').borderRadius(4).margin({ left: 8 })
                      .onClick(() => { console.info('[MapPage] 点击取消'); this.cancelTask(item.taskId); });
                  }
                  .width('100%').margin({ top: 8 });
                } else if (item.state === DownloadState.PAUSED) {
                  Row() {
                    Button('恢复').fontSize(11).height(28).padding({ left: 12, right: 12 })
                      .backgroundColor('#67C23A').borderRadius(4)
                      .onClick(() => { console.info('[MapPage] 点击恢复'); this.resumeTask(item.taskId); });
                    Button('取消').fontSize(11).height(28).padding({ left: 12, right: 12 })
                      .backgroundColor('#F56C6C').borderRadius(4).margin({ left: 8 })
                      .onClick(() => { console.info('[MapPage] 点击取消'); this.cancelTask(item.taskId); });
                  }
                  .width('100%').margin({ top: 8 });
                } else if (item.state === DownloadState.FAILED) {
                  Row() {
                    Button('重试').fontSize(11).height(28).padding({ left: 12, right: 12 })
                      .backgroundColor('#409EFF').borderRadius(4)
                      .onClick(() => { console.info('[MapPage] 点击重试'); this.resumeTask(item.taskId); });
                    Button('删除').fontSize(11).height(28).padding({ left: 12, right: 12 })
                      .backgroundColor('#F56C6C').borderRadius(4).margin({ left: 8 })
                      .onClick(() => { console.info('[MapPage] 点击删除'); this.cancelTask(item.taskId); });
                  }
                  .width('100%').margin({ top: 8 });
                }
              }
              .width('100%').padding(12).backgroundColor('#FFFFFF').borderRadius(8)
              .margin({ left: 12, right: 12, top: 8 });
            }, (item: TaskDisplayItem) => 'task_' + item.taskId + '_' + item.state);
          }
          .width('100%');
        }
        .layoutWeight(1);
      }
      Column().width('100%').layoutWeight(this.displayItems.length > 0 ? 0 : 1);

      // ── 底栏操作 ──────────────────────────────────────
      Row() {
        Button('暂停全部')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor('#E6A23C')
          .borderRadius(6)
          .onClick(() => {
            this.pauseAll();
          });

        Button('恢复全部')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor('#67C23A')
          .borderRadius(6)
          .margin({ left: 12 })
          .onClick(() => {
            this.resumeAll();
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#FFFFFF');
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7FA');
  }

  /**
   * 根据状态获取进度条颜色
   */
  private getProgressColor(state: DownloadState): string {
    switch (state) {
      case DownloadState.DOWNLOADING:
        return '#409EFF';
      case DownloadState.PAUSED:
        return '#E6A23C';
      case DownloadState.COMPLETED:
        return '#67C23A';
      case DownloadState.FAILED:
        return '#F56C6C';
      default:
        return '#C0C4CC';
    }
  }
}
