# 鸿蒙端弹层标准（菜单 / 底部表单 / 确认对话框 / 轻提示）

> 状态：已决定（2026-11-28）
>
> 本文是四类弹层的 API、材质、例外和验收正本；新增、修改或排查弹层前阅读。
>
> 适用：`apps/harmony` 内所有浮在内容之上的界面。新增或修改弹层前先读本文；视觉以鸿蒙官方
> 弹层为准，信息组织（分组、当前值、二级箭头）借鉴 iOS。共享封装在
> `entry/src/main/ets/components/common/UiOverlay.ets`。

## 1. 为什么

- 自造的「Stack + 半透明遮罩」只盖住应用窗口，盖不到系统状态栏和底部导航条，遮罩边缘发亮，
  与系统弹层割裂（真机反馈：首页电脑切换菜单）。
- 各处弹层手写背景、圆角、阴影，行距和图标密度不一，没有系统材质，深浅色下观感不一致。
- 系统弹层自带蒙层范围、阴影、材质、点外部 / 返回键关闭、无障碍焦点和动效，Light / Dark 由系统适配。

## 2. 前提：系统材质

依据 API 26 官方指南「组件适配沉浸光感 › 弹窗类组件」「沉浸光感简介 › 沉浸式空间动效」和 `@ohos.arkui.uiMaterial`：

- 应用 `module.json5` 没有配置 `ohos.arkui.UIMaterial.state`，处于 DEFAULT 模式。此模式下只有
  Dialog、Toast 在**未自定义背景色、模糊、阴影**时默认带沉浸材质；Menu、Popup、Sheet 默认没有。
- **不打开应用级开关**：它会同时改变 Navigation、Tabs、Toggle、Select 等组件，影响面过大。
- **菜单和 Popup 不设组件级 `systemMaterial`**（2026-11-28 决定）：组件级沉浸材质会同时开启系统的
  沉浸式空间动效（菜单「形变弹出 + 边缘流光」）和实时背景采样。真机反馈打开菜单时「黑白交替闪烁」，
  与引入组件级 THICK 材质的时间一致，且所有加了材质的菜单都有、未加材质的底部表单没有。因此菜单和 Popup
  回到系统默认样式（不透明系统背景 + 系统阴影 / 圆角），换取稳定的打开过程；视觉上不再是毛玻璃。
  `uiMenuMaterial()` / `uiPopupMaterial()` 仅为兼容保留，新场景要用材质须真机验证无闪烁并在本文登记。
- Dialog、Toast 保持系统默认（系统自带材质与空间动效，不在业务侧改动）；若真机确认对话框也闪烁，
  再统一评估是否传 `uiMaterial.Material.empty` 关闭。
- 给弹层主动设置背景色、模糊、阴影会让系统材质失效，所以菜单和对话框**不写**这些属性。
- 低算力设备系统会自动退回不透明背景，不需要业务判断。

## 3. 四类弹层

### 3.1 操作菜单（对应 iOS 下拉菜单）

- API：`bindMenu(isShow, builder, uiMenuOptions(onDisappear, placement))`，内容用
  `Menu` / `MenuItemGroup` / `MenuItem`。无蒙层（系统非模态菜单），点外部、返回键关闭由系统处理；
  `onDisappear` 只负责把受控的 `isShow` 复位。
- 样式：`uiMenuOptions` 不设 `systemMaterial`（见第 2 节），也不设背景色、圆角、阴影，全部用系统默认。
- 打开 / 关闭：受控 `isShow` 直接赋值，**不要包在 `animateTo` 里**（系统菜单自带出入场动效）；打开时
  菜单内容不要发生高度变化（异步加载的数据先占位同高，或在打开前准备好）。
- 分组：用 `MenuItemGroup` 分组，系统自带组间分隔；需要组标题时用 `MenuItemGroup({ header })`。
  分组顺序参考 iOS：主操作 / 组织方式 / 筛选 / 显示 / 危险操作。
- 行：每项 `symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.xxx'))` + `content`。
  iOS 的「当前值」副标题放右侧 `labelInfo`。图标资源名先在 SDK `ets-loader/sysResource.js` 中确认存在。
- 当前选中：`.selected(bool).selectIcon(true)`，不画底色。
- 二级：`MenuItem({ ..., builder })`，菜单根节点设
  `.subMenuExpandingMode(SubMenuExpandingMode.STACK_EXPAND)`，系统给出二级箭头与叠层展开。
- 危险项（删除、归档、退出）：`.contentFontColor($r('app.color.danger'))`，放在最后一组。
- 说明性文字（同步中、仅本机生效等）放到对应项的 `labelInfo` 或组标题，不额外画文字行。
- 例外：菜单里必须放滑杆、输入框等控件时才用 `bindPopup`，`mask: false`，不设 `systemMaterial`，
  不自画背景色和阴影。

### 3.2 底部表单（bindSheet）

- API：`bindSheet($$open, builder, uiSheetOptions(title, onDisappear, height?, extras?))`。
  `extras` 是 `UiSheetExtras`，字段均可省略：
  - `detents`：列表或浏览类用 `[SheetSize.MEDIUM, SheetSize.LARGE]`；设置后忽略 `height`。
  - `onWillDismiss`：下滑、点蒙层、点系统关闭按钮前拦截。需要把「关闭」映射成取消（分享、来源、目录选择、
    外部分享等），或有未保存改动先 `uiConfirm` 时使用；放行时调用 `action.dismiss()`。
  - `mode`：默认不设（`SheetMode.OVERLAY`），规则见下方「平板分栏」。
  - `preferType`：默认 `SheetType.BOTTOM`。
- 结构：系统标题 + 系统关闭按钮 + 拖动条。短表单用默认的 `SheetSize.FIT_CONTENT`。
- 表单内的少量整行动作用共享组件 `UiSheetActionRow({ label, symbol, destructive?, actionEnabled?, onAction })`
  （44vp、图标 + 文字、无自绘底色）；超过 3 个平级动作改用操作菜单。
- 背景 `app.color.bg_card`，蒙层 `app.color.overlay`（base / dark 成对）。官方不建议大面积弹层开沉浸材质，
  所以表单不设 `systemMaterial`。
- 表单内主按钮：胶囊、`chat_cta` / `chat_cta_text`，高度 50vp，满宽；输入为空等不可提交时禁用并降为 0.45 透明度。
- 禁止再自造「Stack + 遮罩」的底部面板。
- **例外：自带导航标题栏的浏览类表单**（目前只有文件夹浏览 `WorkdirBrowser`）。内容自己有「返回 / 标题 / 操作」
  一层标题栏、会在表单内逐级进入子目录和预览，再叠系统标题和关闭按钮会出现两层标题。此类表单用
  `workdirBrowserSheetOptions(onDisappear)`：基于 `uiSheetOptions`，高度 LARGE、保留拖动条，去掉系统标题
  和系统关闭按钮；标题栏左侧按钮在根目录显示「关闭」（xmark），在子目录、搜索、预览中显示「返回」
  （chevron_left），下滑仍可直接关闭。新增同类表单须在此登记。
- **平板分栏**（依据 API 26「半模态转场」SheetMode / SheetType 说明）：
  - `SheetMode.EMBEDDED` 只能挂在 Page 或 NavDestination 上，表单显示在该页面内的顶层。鸿蒙首页的列表栏和
    详情栏同属 `TaskListPage` 这一个 Page（详情栏不是独立 NavDestination），所以 EMBEDDED **不能**把表单限制在
    详情栏内，仍会盖住左侧列表；它的实际作用是「之后推入的新页面可以盖在表单上、返回后表单内容保留」。
    因此默认不设 mode（OVERLAY），只有表单里会 `router.pushUrl` 到新页面并需要回来继续时才用 EMBEDDED，
    且必须在页面已挂载后再打开。
  - 模态表单在分栏下盖住整个窗口（含左侧列表）是预期行为，与系统一致；不要为此改回自造的详情栏遮罩。
  - 窗口宽度 ≥ 600vp 时系统默认把未指定类型的表单显示为居中 / 跟手样式；本标准固定 `BOTTOM`，保证
    手机、折叠和平板形态一致。宽屏上锚定在某个按钮、只含几项操作的表单可改 `preferType: SheetType.POPUP`
    （跟手样式，不支持下滑关闭），或者直接用操作菜单。
  - `SheetType.SIDE`（API 20+，宽屏侧边）只在内容是完整的二级流程、且需要保留主内容可见时考虑，使用前在本文登记。
- 两个表单不要绑在同一节点；一个表单关闭后再打开另一个，结果在 `onDisappear` 里交出（避免叠层）。

### 3.3 确认对话框

- API：`uiConfirm(this.getUIContext(), uiConfirmCopy(title, message, confirm, cancel, destructive?))`，
  返回 `Promise<boolean>`；底层系统 AlertDialog，不设背景色，保留系统默认的 ULTRA_THICK 材质。
- 只需要用户读完、没有取消分支的说明（如推送权限说明）用通知变体
  `uiNotice(this.getUIContext(), title, message, acknowledge)`，单个「知道了」类按钮，返回 `Promise<void>`；
  同样点蒙层不关闭，返回键等同确认。
- 取消在左、确认在右（DESIGN.md「Dialog & Modal」按钮顺序）；点蒙层不关闭（防误触），返回键等同取消。
- 危险操作 `copy.destructive = true`，确认按钮用 danger 色。文案：标题说动作，正文一句说后果。
- 三个及以上平级选项不要用 ActionSheet / 对话框，改用操作菜单。

### 3.4 轻提示

- UI 层用 `uiToast(this.getUIContext(), message)`（`UIContext.getPromptAction().showToast`），2 秒，
  不设背景色以保留系统 THICK 材质。只报告已完成或失败的短结果，不承载操作。
- 存量的全局 `promptAction.showToast` 视觉一致，迁移时顺手替换即可；`core/` 等无 UIContext 的层可保留。
- 需要「撤销 / 重试」等操作时，另行评估 HDS 的 `HdsSnackBar`，不要在 Toast 上叠按钮。

## 4. 不在本标准内

- 图片 / 文件全屏查看器（媒体查看器，点外部即关闭）。
- 新建任务草稿、模块详情等整页覆盖面板（属于页面，不是弹层）。
- HDS 目前没有菜单、对话框、表单组件（SDK `hms/ets/api` 只有 HdsNavigation、HdsTabs、HdsSideMenu、
  HdsSideBar、HdsActionBar、HdsListItem、HdsSnackBar、HdsColorPicker）；有新组件时再更新本文。

## 5. 调试日志

`UiOverlay.ets` 提供 `uiOverlayTrace(tag, event)` / `uiOverlayBuildId(tag)`，hilog tag 为 `CindyOverlay`：

- 打开入口先调 `uiOverlayTrace(tag, 'open')`（重置计时和构建计数）。
- `uiMenuOptions(onDisappear, placement, tag)`、`UiSheetExtras.traceTag` 自动记录
  willAppear / didAppear / willDisappear / disappear。
- 弹层 builder 根节点加 `.id(uiOverlayBuildId(tag))`，每次内容被重新创建记一条 `build`。
- 每条日志带距 open 的毫秒数、构建次数、当前深浅色（`colorMode`）。真机排查：
  `hdc -t "$HARMONY_TARGET_ID" hilog | rg CindyOverlay`。正常一次打开应为 open → build(1) → willAppear → didAppear；
  多次 build 说明打开过程中被重建，colorMode 变化说明深浅色在切换。

## 6. 迁移检查单

1. 弹层属于哪一类，按第 3 节选 API；不再新增 `xxxLayer()` + 遮罩的自造浮层。
2. 删除自画的背景色、边框、圆角、阴影、遮罩色；颜色只用 `$r('app.color.*')`。
3. 打开 / 关闭状态仍由原 `@State` 驱动，`onDisappear` 复位；`onBackPress` 里原有的关闭分支可保留。
4. 原有业务回调、文案、可用性判断不变；新增文案只往 string.json 末尾追加并补齐五种语言。
5. 真机验收：Light / Dark、折叠 / 展开、点外部关闭、返回键、系统栏区域无亮边。
