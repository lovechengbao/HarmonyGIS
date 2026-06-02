/**
 * MapPage - 地图主页面
 *
 * 基于 OpenHarmony API 11 的 GIS 地图显示页面，
 * 提供地图加载、缩放、平移、定位等基础功能。
 */

import router from '@ohos.router';

// 地图状态接口
interface MapState {
  zoomLevel: number;
  centerLatitude: number;
  centerLongitude: number;
  isLayerPanelVisible: boolean;
  currentLayer: string;
}

@Entry
@Component
struct MapPage {
  @State zoomLevel: number = 10;
  @State centerLatitude: number = 39.9042;
  @State centerLongitude: number = 116.4074;
  @State isLayerPanelVisible: boolean = false;
  @State currentLayer: string = 'standard';
  @State mapLoading: boolean = true;
  @State locationText: string = '北京市';

  private readonly MIN_ZOOM: number = 3;
  private readonly MAX_ZOOM: number = 18;

  // 地图图层列表
  private layers: LayerItem[] = [
    { name: '标准地图', key: 'standard', icon: '🌐' },
    { name: '卫星影像', key: 'satellite', icon: '🛰️' },
    { name: '地形图', key: 'terrain', icon: '⛰️' },
    { name: '交通图', key: 'traffic', icon: '🚗' },
  ];

  aboutToAppear(): void {
    console.info('[HarmonyGIS] MapPage aboutToAppear');
    // 模拟地图加载
    setTimeout(() => {
      this.mapLoading = false;
    }, 1500);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 地图主区域
      Column() {
        // 地图容器
        Stack({ alignContent: Alignment.Center }) {
          if (this.mapLoading) {
            // 加载状态
            Column() {
              LoadingProgress()
                .width(48)
                .height(48)
                .color(Color.Blue);
              Text('地图加载中...')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ top: 12 });
            }
            .width('100%')
            .height('100%')
            .backgroundColor('#F0F0F0')
            .justifyContent(FlexAlign.Center);
          } else {
            // 地图显示区域
            Column() {
              // 这里将集成 HarmonyOS Map 组件或自定义地图渲染
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor('#EAEAEA');

              // 坐标网格模拟
              Grid()
                .width('100%')
                .height('100%')
                .columnsTemplate('1fr 1fr 1fr')
                .rowsTemplate('1fr 1fr 1fr');
            }
            .width('100%')
            .height('100%');

            // 地图信息水印
            Text(`© HarmonyGIS | Zoom: ${this.zoomLevel}`)
              .fontSize(10)
              .fontColor('#999999')
              .position({ bottom: 8, right: 12 });
          }
        }
        .width('100%')
        .height('100%')
        .layoutWeight(1);

        // 底部信息栏
        Row() {
          Text(this.locationText)
            .fontSize(14)
            .fontColor('#333333')
            .layoutWeight(1);

          Text(`${this.centerLatitude.toFixed(4)}, ${this.centerLongitude.toFixed(4)}`)
            .fontSize(12)
            .fontColor('#999999');
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#FFFFFF')
        .borderRadius(0);
      }
      .width('100%')
      .height('100%');

      // 顶部标题栏
      Row() {
        Text('HarmonyGIS')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF');

        Blank();

        // 图层按钮
        Image($r('app.media.ic_layer'))
          .width(24)
          .height(24)
          .onClick(() => {
            this.isLayerPanelVisible = !this.isLayerPanelVisible;
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#007AFF');

      // 右侧缩放控件
      Column() {
        Button({ type: ButtonType.Circle }) {
          Text('+')
            .fontSize(24)
            .fontColor('#333333');
        }
        .width(44)
        .height(44)
        .backgroundColor('#FFFFFF')
        .shadow({ radius: 4, color: 'rgba(0,0,0,0.15)' })
        .onClick(() => {
          this.zoomIn();
        });

        Text(`${this.zoomLevel}`)
          .fontSize(12)
          .fontColor('#666666')
          .margin({ top: 4, bottom: 4 });

        Button({ type: ButtonType.Circle }) {
          Text('-')
            .fontSize(24)
            .fontColor('#333333');
        }
        .width(44)
        .height(44)
        .backgroundColor('#FFFFFF')
        .shadow({ radius: 4, color: 'rgba(0,0,0,0.15)' })
        .onClick(() => {
          this.zoomOut();
        });
      }
      .position({ right: 16, top: 80 })
      .space(0);

      // 底部定位按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_location'))
          .width(24)
          .height(24);
      }
      .width(48)
      .height(48)
      .backgroundColor('#FFFFFF')
      .shadow({ radius: 4, color: 'rgba(0,0,0,0.15)' })
      .position({ right: 16, bottom: 80 })
      .onClick(() => {
        this.onLocationClick();
      });

      // 图层选择面板
      if (this.isLayerPanelVisible) {
        Column() {
          Text('图层选择')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ bottom: 12 });

          ForEach(this.layers, (item: LayerItem, index: number) => {
            Row() {
              Text(item.icon)
                .fontSize(18)
                .margin({ right: 12 });

              Text(item.name)
                .fontSize(14)
                .fontColor('#333333')
                .layoutWeight(1);

              if (this.currentLayer === item.key) {
                Text('✓')
                  .fontSize(16)
                  .fontColor('#007AFF');
              }
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.switchLayer(item.key);
              this.isLayerPanelVisible = false;
            });
          });
        }
        .width(180)
        .padding(16)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .shadow({ radius: 8, color: 'rgba(0,0,0,0.2)' })
        .position({ right: 56, top: 80 });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5');
  }

  /**
   * 放大
   */
  zoomIn(): void {
    if (this.zoomLevel < this.MAX_ZOOM) {
      this.zoomLevel++;
      console.info(`[HarmonyGIS] Zoom in to level ${this.zoomLevel}`);
    }
  }

  /**
   * 缩小
   */
  zoomOut(): void {
    if (this.zoomLevel > this.MIN_ZOOM) {
      this.zoomLevel--;
      console.info(`[HarmonyGIS] Zoom out to level ${this.zoomLevel}`);
    }
  }

  /**
   * 切换图层
   */
  switchLayer(layerKey: string): void {
    this.currentLayer = layerKey;
    console.info(`[HarmonyGIS] Switch layer to ${layerKey}`);
  }

  /**
   * 定位点击
   */
  onLocationClick(): void {
    console.info('[HarmonyGIS] Location button clicked');
    // TODO: 集成 @ohos.geo_location 获取当前位置
    AlertDialog.show({
      title: '定位',
      message: '正在获取当前位置...',
      confirm: { value: '确定' },
    });
  }
}

// 图层项接口
interface LayerItem {
  name: string;
  key: string;
  icon: string;
}
