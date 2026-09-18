/* ==========================================================================
   TableLite 使用说明书 —— 页面脚本
   三件事：
     1. 根据下面的目录表生成左侧导航与上一页/下一页，并在导航顶部放外观切换按钮
     2. 鼠标移到「控件清单」的某一行时，高亮线框图上对应的编号圆点
     3. 外观切换按钮：跟随系统 → 浅色 → 深色 循环，实际状态由 theme.js 管
   ========================================================================== */

const MANUAL_PAGES = [
  { file: 'index.html',              n: '·',   title: '说明书首页' },
  { file: '01-connections.html',     n: '01',  title: '连接' },
  { file: '02-workspace.html',       n: '02',  title: '界面结构' },
  { file: '03-data-browsing.html',   n: '03',  title: '浏览表数据' },
  { file: '04-data-editing.html',    n: '04',  title: '编辑数据' },
  { file: '05-filtering.html',       n: '05',  title: '过滤器' },
  { file: '06-query-editor.html',    n: '06',  title: '查询编辑器' },
  { file: '07-schema-view.html',     n: '07',  title: '表结构视图' },
  { file: '08-import-export.html',   n: '08',  title: '导入与导出' },
  { file: '09-readonly.html',        n: '09',  title: '只读模式' },
  { file: '10-ssh-tunnel.html',      n: '10',  title: 'SSH 隧道' },
  { file: '11-preferences.html',     n: '11',  title: '偏好设置' },
  { file: '12-shortcuts.html',       n: '12',  title: '快捷键总表' },
  { file: '13-feedback.html',        n: '13',  title: '提示与错误' }
];

/* 外观三态，顺序就是点击的循环顺序 */
const THEME_MODES = [
  {
    id: 'system',
    label: '跟随系统',
    next: '浅色',
    icon: '<svg viewBox="0 0 24 24" aria-hidden="true">' +
          '<circle cx="12" cy="12" r="7.5"/>' +
          '<path class="fill" d="M12 4.5a7.5 7.5 0 0 0 0 15z"/>' +
          '</svg>'
  },
  {
    id: 'light',
    label: '浅色',
    next: '深色',
    icon: '<svg viewBox="0 0 24 24" aria-hidden="true">' +
          '<circle cx="12" cy="12" r="4.2"/>' +
          '<path d="M12 2.5v2.2M12 19.3v2.2M4.6 4.6l1.6 1.6M17.8 17.8l1.6 1.6' +
          'M2.5 12h2.2M19.3 12h2.2M4.6 19.4l1.6-1.6M17.8 6.2l1.6-1.6"/>' +
          '</svg>'
  },
  {
    id: 'dark',
    label: '深色',
    next: '跟随系统',
    icon: '<svg viewBox="0 0 24 24" aria-hidden="true">' +
          '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/>' +
          '</svg>'
  }
];

function buildThemeToggle() {
  const theme = window.ManualTheme;
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'theme-toggle';

  const render = () => {
    const mode = theme ? theme.get() : 'system';
    const i = THEME_MODES.findIndex((m) => m.id === mode);
    const current = THEME_MODES[i < 0 ? 0 : i];
    button.dataset.mode = current.id;
    button.innerHTML = current.icon;
    button.title = '外观：' + current.label + '（点击切换为' + current.next + '）';
    button.setAttribute('aria-label', '外观：' + current.label);
  };

  button.addEventListener('click', () => {
    if (!theme) return;
    const i = THEME_MODES.findIndex((m) => m.id === theme.get());
    theme.set(THEME_MODES[(i + 1) % THEME_MODES.length].id);
  });
  // theme.js 改完状态后会广播，这里跟着换图标
  window.addEventListener('manual:themechange', render);

  render();
  return button;
}

(function buildNavigation() {
  const host = document.querySelector('nav.toc');
  if (!host) return;
  host.innerHTML = '';   // 清掉 HTML 里的兜底导航，重新生成一遍（这次会标出当前页）

  const here = location.pathname.split('/').pop() || 'index.html';

  const head = document.createElement('div');
  head.className = 'brandrow';
  head.innerHTML = '<div class="brand"><b>TableLite</b><span>使用说明书</span></div>';
  head.appendChild(buildThemeToggle());
  host.appendChild(head);

  const sub = document.createElement('div');
  sub.className = 'sub';
  sub.textContent = 'macOS 原生 MySQL / MariaDB 客户端';
  host.appendChild(sub);

  const list = document.createElement('ol');
  for (const page of MANUAL_PAGES) {
    const li = document.createElement('li');
    const a = document.createElement('a');
    a.href = page.file;
    a.innerHTML =
      '<span class="n">' + page.n + '</span><span>' + page.title + '</span>';
    if (page.file === here) a.setAttribute('aria-current', 'page');
    li.appendChild(a);
    list.appendChild(li);
  }
  host.appendChild(list);
})();

(function buildPager() {
  const host = document.querySelector('.pager');
  if (!host) return;

  const here = location.pathname.split('/').pop() || 'index.html';
  const i = MANUAL_PAGES.findIndex((p) => p.file === here);
  if (i < 0) return;

  const prev = MANUAL_PAGES[i - 1];
  const next = MANUAL_PAGES[i + 1];

  const link = (page, dir) =>
    page
      ? '<a href="' + page.file + '"><span class="dir">' + dir + '</span>' +
        page.n + ' · ' + page.title + '</a>'
      : '';

  host.innerHTML =
    prev ? link(prev, '← 上一节') : '<span class="spacer"></span>';
  host.innerHTML += next ? link(next, '下一节 →') : '<span class="spacer"></span>';
})();

(function linkHotspots() {
  const rows = document.querySelectorAll('table.controls tbody tr[data-hot]');
  if (!rows.length) return;

  const clear = () => {
    document
      .querySelectorAll('svg .hot.active')
      .forEach((el) => el.classList.remove('active'));
  };

  const light = (value) => {
    clear();
    document
      .querySelectorAll('svg .hot[data-hot="' + value + '"]')
      .forEach((el) => el.classList.add('active'));
  };

  rows.forEach((row) => {
    const value = row.getAttribute('data-hot');
    row.addEventListener('mouseenter', () => light(value));
    row.addEventListener('mouseleave', clear);
    row.addEventListener('focusin', () => light(value));
  });

  // 反向：鼠标移到图上的圆点，高亮表格行
  document.querySelectorAll('svg .hot[data-hot]').forEach((dot) => {
    const value = dot.getAttribute('data-hot');
    dot.style.cursor = 'help';
    dot.addEventListener('mouseenter', () => {
      rows.forEach((row) => {
        row.style.background =
          row.getAttribute('data-hot') === value ? 'var(--panel-2)' : '';
      });
    });
    dot.addEventListener('mouseleave', () => {
      rows.forEach((row) => (row.style.background = ''));
    });
  });
})();
