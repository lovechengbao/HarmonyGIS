/**
 * SettingsPage - 设置页面
 *
 * TODO: 实现应用设置功能
 */

@Entry
@Component
struct SettingsPage {
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('设置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333');

        Text('设置页面')
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
