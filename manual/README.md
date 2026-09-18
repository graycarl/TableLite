# TableLite 使用说明书

由 14 个静态 HTML 页面组成的软件说明书。每个界面都用**内联 SVG 线框图**画出来，
图上的编号圆点对应表格里的控件说明。

## 怎么看

在线看：<https://graycarl.github.io/TableLite/>

或者直接双击 `index.html` 用浏览器打开。没有构建步骤、没有依赖、不需要起服务器。

```
open manual/index.html
```

页面默认跟随系统的浅色 / 深色模式；左侧导航顶部的按钮可以在
「跟随系统 → 浅色 → 深色」之间手动切换，选择记在浏览器的 localStorage 里。

需要纸面版或 PDF 时，用浏览器的「打印 → 存储为 PDF」。打印样式已经排好：
导航栏和页码会自动隐藏，线框图不会被切页。

## 内容

| 文件 | 内容 |
| --- | --- |
| `index.html` | 整体界面一览、功能与章节对照 |
| `01-connections.html` | 连接列表、连接表单、测试连接 |
| `02-workspace.html` | 工具栏、左侧栏、标签栏、状态栏、空状态 |
| `03-data-browsing.html` | 数据网格、分页、排序、快速查看、复制 |
| `04-data-editing.html` | 各类编辑器、增删改行、预览、提交、并发限制 |
| `05-filtering.html` | 行过滤器、操作符、高级模式、列过滤器、快速过滤 |
| `06-query-editor.html` | 编辑器、执行、结果标签、查询历史、Console Log |
| `07-schema-view.html` | 列 / 索引 / 外键 / 触发器 / 建表语句 |
| `08-import-export.html` | 导出面板、CSV 导入向导三步、从 CSV 建表 |
| `09-readonly.html` | 只读标识、被禁止的操作、语句拦截规则 |
| `10-ssh-tunnel.html` | 三种认证方式、指纹警告、错误提示、清理要求 |
| `11-preferences.html` | 七个偏好分类的全部选项 |
| `12-shortcuts.html` | 快捷键速查表 |
| `13-feedback.html` | 四种反馈形态、错误面板结构、文案规范 |

## 怎么发布

推送到 `main` 后由 `.github/workflows/pages.yml` 自动部署到 GitHub Pages，
只把 `manual/` 目录作为站点根，站点地址 <https://graycarl.github.io/TableLite/>。
也可以在 Actions 页面手动 `Run workflow` 触发。

## 结构约定

```
manual/
├── index.html
├── 01-…13-*.html
└── assets/
    ├── manual.css     页面排版 + 线框图的绘制约定
    ├── theme.js       首屏前定下浅色 / 深色（html[data-theme]）；按钮由 manual.js 生成
    └── manual.js      生成左侧导航与上下页；外观切换按钮；编号热点与表格行联动
```

### 浅色 / 深色的写法

- `manual.css` 里 `:root` 是浅色，深色同一份值写在**两个入口**：
  `@media (prefers-color-scheme: dark)`（`html` 上没有 `data-theme` 时，即「跟随系统」）
  与 `:root[data-theme="dark"]`（读者手工选的深色）。**改颜色时两处要一起改。**
- 页面 `<head>` 里同步加载 `assets/theme.js`，它负责在首屏前把 `data-theme` 定下来，
  读不到 localStorage 时退回跟随系统。新增页面时记得照着抄这一行。
- 外观按钮由 `manual.js` 生成，所以禁用脚本时没有按钮，但页面仍然跟随系统。

### 线框图怎么写的

- 每张图都是一个内联 `<svg>`，`viewBox` 统一 **1000 宽**，坐标按 4pt 网格对齐。
- **不写死颜色**，全部用 CSS class（`s-field`、`lnA`、`mut`、`kw` …），
  定义在 `assets/manual.css` 里。因此线框图会自动跟随系统的浅色 / 深色模式。
- 编号热点写成 `<g class="hot" data-hot="3">`，说明表里写成 `<tr data-hot="3">`。
  `manual.js` 让两者联动：鼠标移到表格行上，图上的圆点会变橙色。
- 页面顶部的 `<nav class="toc">` 里有一份**兜底导航**，`manual.js` 会把它清掉重新生成。
  禁用脚本时页面依然能读。

### 加一张新图

1. 在正文里插 `<figure><svg viewBox="0 0 1000 H">…</svg><figcaption>…</figcaption></figure>`。
2. 用 `assets/manual.css` 里已有的 class，别写 `fill="#fff"` 这类硬编码（半透明白除外）。
3. 图题统一写 `<b>图 X-Y</b>　说明文字`。
4. 改完跑一遍校验（会检查 SVG 是否合法、有没有零尺寸元素、文字有没有跑出 viewBox）：

```sh
python3 - <<'PY'
import re, glob
import xml.etree.ElementTree as ET
bad = 0
for f in sorted(glob.glob('manual/*.html')):
    h = open(f, encoding='utf-8').read()
    for i, m in enumerate(re.finditer(r'<svg\b.*?</svg>', h, re.S), 1):
        try:
            ET.fromstring(m.group(0))
        except ET.ParseError as e:
            bad += 1; print('✗', f, i, e)
print('OK' if not bad else bad)
PY
```

## 与 specs 的关系

说明书描述的是**用户看到什么**，和 `../specs/` 是同一层的内容，只是形式不同：
`specs/` 是给实现者读的规则，`manual/` 是给人读的图解。

两者出现不一致时，以 `specs/` 为准，然后回来改说明书。
实现细节（类名、SQL、存储路径）**不要**写进这里。
