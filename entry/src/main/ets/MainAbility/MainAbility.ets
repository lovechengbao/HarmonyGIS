/**
 * MainAbility - 应用主 Ability
 */

import UIAbility from '@ohos.app.ability.UIAbility';
import Want  from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';

export default class MainAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[HarmonyGIS] MainAbility onCreate');
  }

  onDestroy(): void {
    console.info('[HarmonyGIS] MainAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('[HarmonyGIS] MainAbility onWindowStageCreate');

    windowStage.loadContent('pages/MapPage', (err) => {
      if (err.code) {
        console.error(`[HarmonyGIS] Failed to load content: ${JSON.stringify(err)}`);
        return;
      }
    });
  }

  onWindowStageDestroy(): void {
    console.info('[HarmonyGIS] MainAbility onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[HarmonyGIS] MainAbility onForeground');
  }

  onBackground(): void {
    console.info('[HarmonyGIS] MainAbility onBackground');
  }
}
