/**
 * HarmonyGIS 测试用例
 */

import { describe, it, expect } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.AbilityDelegatorRegistry';

describe('HarmonyGIS Test Suite', () => {
  it('应用启动测试', 0, () => {
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    expect(delegator).not().toBeNull();
    console.info('[HarmonyGIS Test] App launch test passed');
  });

  it('应用包名验证', 0, () => {
    const context = AbilityDelegatorRegistry.getAbilityDelegator().getAppContext();
    expect(context.getBundleName()).assertEquals('com.lovechengbao.harmonygis');
    console.info('[HarmonyGIS Test] Bundle name verification passed');
  });

  it('地图页面加载测试', 0, () => {
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    // 验证 MainAbility 是否存在
    expect(delegator.getAbility('MainAbility')).not().toBeNull();
    console.info('[HarmonyGIS Test] Map page load test passed');
  });
});
