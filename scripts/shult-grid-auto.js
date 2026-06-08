/**
 * 舒尔特方格自动完成脚本
 *
 * 用法：
 * 1. 手机 Chrome 打开 toolonline.net/shult-grid
 * 2. 地址栏输入 javascript: 前缀粘贴此脚本（或用 DevTools Console）
 * 3. 自动按 1→25 顺序依次点击
 */

(function () {
  'use strict';

  // ═══════════════════════════════════════
  // 策略：遍历常见 DOM 结构，找到所有数字格子
  // ═══════════════════════════════════════

  /** 从 DOM 中提取所有 (数字, 元素) 对 */
  function findCells() {
    // 尝试常见的格子选择器
    const selectors = [
      '.grid-cell', '.cell', '.number',          // 通用 class
      '.shult-cell', '.schulte-cell',            // 舒尔特常见命名
      '[data-number]', '[data-value]',           // data 属性
      '.grid-item', '.box', '.square',           // 通用命名
      'td',                                      // 表格型
      '.grid > div', '.grid > span',             // div 网格
      '#grid > div', '#grid > span',
    ];

    for (let i = 0; i < selectors.length; i++) {
      const els = document.querySelectorAll(selectors[i]);
      if (els.length >= 25) {
        // 有足够的格子，尝试提取数字
        const cells = [];
        for (let j = 0; j < els.length; j++) {
          const el = els[j];
          const num = extractNumber(el);
          if (num !== null && num >= 1 && num <= 100) {
            cells.push({ num: num, elem: el });
          }
        }
        if (cells.length >= 25) {
          return cells;
        }
      }
    }

    // 兜底：遍历所有元素找纯数字文本
    const allDivs = document.querySelectorAll('div, span, td, button');
    const fallback = [];
    for (let k = 0; k < allDivs.length; k++) {
      const el = allDivs[k];
      // 跳过太深的嵌套和隐藏元素
      if (el.children.length > 0) continue;
      if (el.offsetParent === null) continue;  // 跳过隐藏元素
      const num = extractNumber(el);
      if (num !== null && num >= 1 && num <= 100) {
        fallback.push({ num: num, elem: el });
      }
    }
    return fallback;
  }

  /** 从元素中提取数字 */
  function extractNumber(el) {
    const text = (el.textContent || '').trim();
    if (/^\d+$/.test(text)) {
      return parseInt(text, 10);
    }
    if (el.hasAttribute('data-number')) {
      return parseInt(el.getAttribute('data-number'), 10);
    }
    if (el.hasAttribute('data-value')) {
      return parseInt(el.getAttribute('data-value'), 10);
    }
    return null;
  }

  /** 模拟点击 */
  function simulateClick(el) {
    // 触发多种事件以兼容不同的事件绑定方式
    ['mousedown', 'mouseup', 'click', 'pointerdown', 'pointerup', 'touchstart', 'touchend'].forEach(function (type) {
      const ev = new MouseEvent(type, { bubbles: true, cancelable: true, view: window });
      el.dispatchEvent(ev);
      const pe = new PointerEvent(type, { bubbles: true, cancelable: true, view: window });
      el.dispatchEvent(pe);
    });
  }

  /** 高亮当前点击的格子 */
  function highlight(el, num) {
    const origBg = el.style.backgroundColor;
    const origOutline = el.style.outline;
    el.style.outline = '4px solid red';
    el.style.backgroundColor = '#ffff00';
    setTimeout(function () {
      el.style.backgroundColor = origBg;
      el.style.outline = origOutline;
    }, 200);
  }

  // ═══════════════════════════════════════
  // 主流程
  // ═══════════════════════════════════════

  const cells = findCells();

  if (cells.length < 25) {
    alert('没找到足够的数字格子（找到 ' + cells.length + ' 个，需要 ≥25 个）\n可能 DOM 结构特殊，需要手动适配。');
    return;
  }

  // 按数字排序
  cells.sort(function (a, b) { return a.num - b.num; });

  console.log('[舒尔特] 找到 ' + cells.length + ' 个数字格子，范围 ' +
    cells[0].num + '~' + cells[cells.length - 1].num);

  // 取前 25 个（最小的 25 个），即 1~25
  const targets = cells.slice(0, 25);

  // 确认：第一个是 1，最后一个是 25
  if (targets[0].num !== 1) {
    console.warn('[舒尔特] 第一个数字不是 1，而是 ' + targets[0].num + '，继续执行...');
  }

  console.log('[舒尔特] 开始自动点击，共 ' + targets.length + ' 步');

  let index = 0;

  function clickNext() {
    if (index >= targets.length) {
      console.log('[舒尔特] ✅ 完成！');
      return;
    }

    const item = targets[index];
    highlight(item.elem, item.num);
    simulateClick(item.elem);

    console.log('[舒尔特] 第 ' + (index + 1) + '/25 步：点击数字 ' + item.num);

    index++;
    // 间隔 80ms（太快可能被反作弊检测）
    setTimeout(clickNext, 80);
  }

  // 倒计时 3 秒开始
  console.log('[舒尔特] 3 秒后开始...');
  let countdown = 3;
  const cdInterval = setInterval(function () {
    console.log('[舒尔特] ' + countdown + '...');
    countdown--;
    if (countdown < 0) {
      clearInterval(cdInterval);
      clickNext();
    }
  }, 1000);
})();
