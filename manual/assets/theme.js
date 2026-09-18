/* ==========================================================================
   TableLite 使用说明书 —— 外观（跟随系统 / 浅色 / 深色）
   在 <head> 里同步加载，先把 <html data-theme> 定下来，避免首屏先亮一下系统主题。
   选择记在 localStorage；按钮本身由 manual.js 生成。
   ========================================================================== */

(function () {
  const KEY = 'tablelite-manual-theme';
  const MODES = ['system', 'light', 'dark'];
  const root = document.documentElement;

  const stored = () => {
    try {
      const value = localStorage.getItem(KEY);
      return MODES.indexOf(value) >= 0 ? value : 'system';
    } catch (e) {
      return 'system';   // 用 file:// 打开时 Safari 不给 localStorage
    }
  };

  const apply = (mode) => {
    if (mode === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', mode);
  };

  window.ManualTheme = {
    modes: MODES.slice(),
    get: stored,
    set(mode) {
      const next = MODES.indexOf(mode) >= 0 ? mode : 'system';
      apply(next);
      try { localStorage.setItem(KEY, next); } catch (e) { /* 记不住就算了 */ }
      window.dispatchEvent(
        new CustomEvent('manual:themechange', { detail: { mode: next } })
      );
    }
  };

  apply(stored());
})();
