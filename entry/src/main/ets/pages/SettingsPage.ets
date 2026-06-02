/**
 * SettingsPage - 设置页面
 *
 * 提供地图显示偏好、缓存管理、数据源配置等设置功能。
 */

import router from '@ohos.router';

// 地图投影类型
enum ProjectionType {
  WebMercator = 'WebMercator',
  WGS84 = 'WGS84',
  GCJ02 = 'GCJ02'
}

// 设置项接口
interface SettingItem {
  title: string;
  summary: string;
  type: SettingType;
  key: string;
  value?: string | boolean | number;
  options?: string[];
}

enum SettingType {
  Switch = 'switch',
  Select = 'select',
  Action = 'action',
  Info = 'info'
}

@Entry
@Component
struct SettingsPage {
  @State cacheEnabled: boolean = true;
  @State highPerformanceMode: boolean = false;
  @State projection: string = 'WebMercator';
  @State cacheSize: string = '256 MB';

  // 设置列表
  private settingsSections: SettingSection[] = [
    {
      title: '地图显示',
      items: [
        {
          title: '投影坐标系',
          summary: '当前使用 WebMercator 投影',
          type: SettingType.Select,
          key: 'projection',
          value: 'WebMercator',
          options: ['WebMercator', 'WGS84', 'GCJ02'],
        },
        {
          title: '高性能模式',
          summary: '启用 GPU 加速渲染',
          type: SettingType.Switch,
          key: 'highPerformance',
          value: false,
        },
      ],
    },
    {
      title: '缓存与存储',
      items: [
        {
          title: '瓦片缓存',
          summary: '缓存地图瓦片以加快加载速度',
          type: SettingType.Switch,
          key: 'cache',
          value: true,
        },
        {
          title: '清除缓存',
          summary: `${this.cacheSize} 缓存数据`,
          type: SettingType.Action,
          key: 'clearCache',
        },
      ],
    },
    {
      title: '关于',
      items: [
        {
          title: '应用版本',
          summary: '1.0.0',
          type: SettingType.Info,
          key: 'version',
        },
        {
          title: 'API 版本',
          summary: 'OpenHarmony API 11',
          type: SettingType.Info,
          key: 'apiVersion',
        },
      ],
    },
  ];

  build() {
    Column() {
      // 顶栏
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('←')
            .fontSize(18)
            .fontColor('#007AFF');
        }
        .backgroundColor('transparent')
        .onClick(() => {
          router.back();
        });

        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .margin({ left: 12 });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF');

      // 设置列表
      List() {
        ForEach(this.settingsSections, (section: SettingSection) => {
          ListItem() {
            Column() {
              Text(section.title)
                .fontSize(12)
                .fontColor('#007AFF')
                .fontWeight(FontWeight.Medium)
                .margin({ top: 16, bottom: 8, left: 16 });
            }
          };

          ForEach(section.items, (item: SettingItem) => {
            ListItem() {
              this.settingRow(item);
            };
          });
        });
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#F5F5F5');
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5');
  }

  /**
   * 设置项行
   */
  @Builder
  settingRow(item: SettingItem) {
    Row() {
      Column() {
        Text(item.title)
          .fontSize(16)
          .fontColor('#333333');

        Text(item.summary)
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      // Switch 类型
      if (item.type === SettingType.Switch) {
        Toggle({ type: ToggleType.Switch, isOn: item.value as boolean })
          .onChange((isOn: boolean) => {
            this.onSettingChange(item.key, isOn);
          });
      }

      // Select 类型
      if (item.type === SettingType.Select) {
        Text('>')
          .fontSize(16)
          .fontColor('#CCCCCC');
      }

      // Action 类型
      if (item.type === SettingType.Action) {
        Text('>')
          .fontSize(16)
          .fontColor('#CCCCCC');
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .onClick(() => {
      if (item.type === SettingType.Action) {
        this.onActionClick(item.key);
      }
      if (item.type === SettingType.Select) {
        this.onSelectClick(item.key, item.options || []);
      }
    });
  }

  /**
   * 设置项变更处理
   */
  onSettingChange(key: string, value: boolean | string): void {
    console.info(`[HarmonyGIS] Setting changed: ${key} = ${value}`);
    switch (key) {
      case 'cache':
        this.cacheEnabled = value as boolean;
        break;
      case 'highPerformance':
        this.highPerformanceMode = value as boolean;
        break;
      default:
        break;
    }
  }

  /**
   * 选择型设置点击
   */
  onSelectClick(key: string, options: string[]): void {
    // TODO: 弹出选择器
    console.info(`[HarmonyGIS] Select clicked: ${key}`);
  }

  /**
   * 操作按钮点击
   */
  onActionClick(key: string): void {
    if (key === 'clearCache') {
      AlertDialog.show({
        title: '清除缓存',
        message: '确定要清除所有地图缓存数据吗？',
        primaryButton: {
          value: '取消',
          action: () => {},
        },
        secondaryButton: {
          value: '确定',
          action: () => {
            this.cacheSize = '0 MB';
            console.info('[HarmonyGIS] Cache cleared');
          },
        },
      });
    }
  }
}

interface SettingSection {
  title: string;
  items: SettingItem[];
}
