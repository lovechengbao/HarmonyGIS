/**
 * HarmonyGIS - OpenHarmony API 11 GIS Application
 */

import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[HarmonyGIS] Ability onCreate');
  }

  onDestroy(): void {
    console.info('[HarmonyGIS] Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('[HarmonyGIS] onWindowStageCreate');
    windowStage.loadContent('pages/MapPage', (err) => {
      if (err.code) {
        console.error(`[HarmonyGIS] Failed to load content: ${err.message}`);
        return;
      }
      console.info('[HarmonyGIS] Succeeded in loading content');
    });
  }

  onWindowStageDestroy(): void {
    console.info('[HarmonyGIS] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[HarmonyGIS] onForeground');
  }

  onBackground(): void {
    console.info('[HarmonyGIS] onBackground');
  }
}
