/**
 * MapPage - 地图主页面
 *
 * TODO: 实现地图显示与交互功能
 */

@Entry
@Component
struct MapPage {
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('HarmonyGIS')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333');

        Text('地图页面')
          .fontSize(14)
          .fontColor('#999999')
          .margin({ top: 8 });
      }
      .justifyContent(FlexAlign.Center);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5');
  }
}
