// ==UserScript==
// @name         舒尔特方格自动完成
// @namespace    https://github.com/lovechengbao/HarmonyGIS
// @version      1.0
// @description  自动按顺序点击数字，快速完成舒尔特方格训练
// @author       HarmonyGIS
// @match        https://toolonline.net/shult-grid*
// @match        https://toolonline.net/*
// @grant        none
// @run-at       document-end
// ==/UserScript==

(function () {
  'use strict';

  const DELAY = 120;        // 每次点击间隔 (ms)，太快可能触发反作弊
  const COUNTDOWN = 2;      // 开始前倒计时 (秒)

  let autoRunning = false;

  // ═══════════════════════════════════════
  // 创建控制按钮
  // ═══════════════════════════════════════

  function createButton() {
    const btn = document.createElement('div');
    btn.id = 'shult-auto-btn';
    btn.textContent = '⚡ 自动';
    btn.style.cssText =
      'position:fixed;bottom:20px;right:20px;z-index:99999;' +
      'padding:12px 18px;background:#ff5722;color:#fff;' +
      'font-size:16px;font-weight:bold;border-radius:50%;' +
      'width:60px;height:60px;display:flex;align-items:center;justify-content:center;' +
      'box-shadow:0 4px 12px rgba(255,87,34,.5);cursor:pointer;' +
      'user-select:none;transition:transform .2s;';
    btn.addEventListener('click', startAuto);
    btn.addEventListener('touchend', function(e) { e.preventDefault(); startAuto(); });
    document.body.appendChild(btn);
  }

  // ═══════════════════════════════════════
  // 探测格子
  // ═══════════════════════════════════════

  function detectGrid() {
    // 策略1: 找包含大量数字子元素的容器
    const containers = document.querySelectorAll('div, table, section, .grid, #grid, [class*="grid"], [class*="shult"], [class*="schulte"]');
    let bestContainer = null;
    let bestScore = 0;

    for (let i = 0; i < containers.length; i++) {
      const c = containers[i];
      const textEls = c.querySelectorAll('div, span, td, li, button, .cell, [class*="cell"], [class*="item"], [class*="num"]');
      const nums = [];
      for (let j = 0; j < textEls.length; j++) {
        const el = textEls[j];
        const text = (el.textContent || '').trim();
        if (/^\d+$/.test(text)) {
          const n = parseInt(text, 10);
          if (n >= 1 && n <= 100) {
            nums.push({ num: n, elem: el });
          }
        }
      }
      // 舒尔特常见: 3x3(9格) 4x4(16格) 5x5(25格) 6x6(36格) 7x7(49格)
      const gridSizes = [9, 16, 25, 36, 49];
      let score = 0;
      for (let k = 0; k < gridSizes.length; k++) {
        if (nums.length === gridSizes[k]) {
          score = gridSizes[k] * 100 + (nums[0].num === 1 ? 50 : 0);
          break;
        }
      }
      if (nums.length >= 9 && score > bestScore) {
        bestScore = score;
        bestContainer = { nums: nums, parent: c };
      }
    }

    // 策略2: 全局搜索所有数字元素
    if (!bestContainer || bestContainer.nums.length < 9) {
      const allNums = [];
      const allEls = document.querySelectorAll('div, span, td, button');
      for (let m = 0; m < allEls.length; m++) {
        const el = allEls[m];
        if (el.children.length > 0) continue;  // 跳过有子节点的容器
        const text = (el.textContent || '').trim();
        if (/^\d+$/.test(text)) {
          const n = parseInt(text, 10);
          if (n >= 1 && n <= 100) {
            allNums.push({ num: n, elem: el });
          }
        }
      }
      const gridSizes = [9, 16, 25, 36, 49];
      for (let k = 0; k < gridSizes.length; k++) {
        if (allNums.length === gridSizes[k]) {
          bestContainer = { nums: allNums, parent: document.body };
          break;
        }
      }
    }

    return bestContainer;
  }

  // ═══════════════════════════════════════
  // 开始自动点击
  // ═══════════════════════════════════════

  function startAuto() {
    if (autoRunning) return;
    autoRunning = true;

    const grid = detectGrid();
    if (!grid || grid.nums.length < 9) {
      alert('未检测到舒尔特方格！\n\n找到的数字元素: ' + (grid ? grid.nums.length : 0) + ' 个\n请先在页面点击开始游戏。');
      autoRunning = false;
      return;
    }

    // 按数字排序，从小到大
    grid.nums.sort(function (a, b) { return a.num - b.num; });
    const targets = grid.nums;

    const size = Math.sqrt(targets.length);
    const count = targets.length;

    console.log('[舒尔特] 检测到 ' + size + '×' + size + ' 方格 (' + count + ' 格)');
    console.log('[舒尔特] 数字范围: ' + targets[0].num + ' ~ ' + targets[count - 1].num);

    // 倒计时
    let remaining = COUNTDOWN;
    updateBtnText('⏳ ' + remaining);
    const cdTimer = setInterval(function () {
      remaining--;
      if (remaining <= 0) {
        clearInterval(cdTimer);
        executeClicks(targets);
      } else {
        updateBtnText('⏳ ' + remaining);
      }
    }, 1000);
  }

  function executeClicks(targets) {
    let index = 0;
    const count = targets.length;

    function clickNext() {
      if (index >= count) {
        updateBtnText('✅ 完成');
        autoRunning = false;
        setTimeout(function () { updateBtnText('⚡ 自动'); }, 2000);
        return;
      }

      const item = targets[index];
      const el = item.elem;

      updateBtnText('▶ ' + (index + 1) + '/' + count);

      // 高亮
      highlight(el);

      // 触发点击事件
      fireClick(el);

      console.log('[舒尔特] ' + (index + 1) + '/' + count + ' → ' + item.num);
      index++;

      // 微调延迟：最后几个可以稍快
      const delay = index > count * 0.8 ? DELAY * 0.6 : DELAY;
      setTimeout(clickNext, delay);
    }

    clickNext();
  }

  // ═══════════════════════════════════════
  // 工具函数
  // ═══════════════════════════════════════

  function fireClick(el) {
    const events = ['touchstart', 'touchend', 'mousedown', 'mouseup', 'click', 'pointerdown', 'pointerup'];
    for (let i = 0; i < events.length; i++) {
      try {
        const opts = { bubbles: true, cancelable: true, view: window };
        if (events[i].startsWith('touch')) {
          el.dispatchEvent(new TouchEvent(events[i], opts));
        } else if (events[i].startsWith('pointer')) {
          el.dispatchEvent(new PointerEvent(events[i], opts));
        } else {
          el.dispatchEvent(new MouseEvent(events[i], opts));
        }
      } catch (_e) {
        // 某些事件类型可能不支持，跳过
      }
    }
  }

  function highlight(el) {
    const orig = el.style.outline;
    el.style.outline = '3px solid #ff5722';
    el.style.outlineOffset = '-1px';
    setTimeout(function () {
      el.style.outline = orig;
    }, 180);
  }

  function updateBtnText(text) {
    const btn = document.getElementById('shult-auto-btn');
    if (btn) {
      btn.textContent = text;
      // 动态调整字号
      if (text.length > 6) {
        btn.style.fontSize = '11px';
      } else {
        btn.style.fontSize = '16px';
      }
    }
  }

  // ═══════════════════════════════════════
  // 初始化
  // ═══════════════════════════════════════

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', createButton);
  } else {
    createButton();
  }

  console.log('[舒尔特] 脚本已加载，点击右下角 ⚡ 按钮自动完成');
})();
