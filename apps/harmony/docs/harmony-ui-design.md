# Cindy 鸿蒙界面规范

本文件是鸿蒙端视觉、组件和折叠形态的设计正本。批次 0 落地共享色彩及字号基础，标题、组件和布局规则是后续迁移目标，不表示现有页面已全部遵循。

## 1. 裁决顺序

| 设计问题 | 依据 |
| --- | --- |
| 怎么呈现 | 鸿蒙官方设计规范。颜色、字号、圆角、间距、图标、标题栏、列表、弹层、按钮和动效优先使用 HDS/ArkUI 系统能力。所有标题栏靠左，包括单栏与双栏的会话详情、伙伴会话、权限/模型/电脑选择面板标题。不延续 D-015 居中规则，不为了居中留对称空列。 |
| 呈现什么 | [Cindy DESIGN](../../../docs/design-rules/DESIGN.md) 决定产品叫法、信息结构、入口与危险操作语义。Cindy 品牌只用于 Logo、应用图标与启动页，品牌深褐 `#241C18`、米白 `#FAECDD`、橙点 `#DF582D` 不作界面强调色。 |
| 如何工作 | [Mobile 行为对齐](./mobile-alignment.md) 和对应 iOS/Mobile 源码决定状态及交互。去掉会话字号 0.84 倍缩放，改用跟随系统字号的角色字阶，不照搬 iOS 的视觉。 |
| 大屏怎么增强 | 鸿蒙自有规则决定三栏、分隔条拖到底全幅、协同展开和伙伴紧凑态。保留已认可的增强，按窗口可用区域、折痕和外设能力实现。 |

颜色和字阶参考华为[系统色彩](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/color-0000001776857164)、[字体](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/font-0000001828772001)，以及 HarmonyOS Design 的 Mobile Theme / Mobile Scale 与组件规格。工程侧以 API 26 SDK 的 ArkUI `ets-loader/sysResource.js` 为准，CSS 参考规格的 px 不直接当作 ArkUI 的 vp 或 fp。

## 2. 基础 Token

### 2.1 颜色和深浅色

系统强调色用于主操作、选中、链接和光标。存量 `app.color.*` 名称一律保留。能一对一对应的角色在 `resources/{base,dark}/element/color.json` 用 `$ohos:color:<名称>` 指向系统同一资源，不在 ArkTS 逐页替换，不在 dark 写死系统蓝。SDK 核对的是 `sys.color.*` 名称，颜色 JSON 使用资源编译器的系统引用语法，两者不要混写。如下的系统色 **无应用 HEX 回退**，两态交给系统解析。专用角色如选中容器不能全用 `accent`，新组件优先用系统控件默认；自绘场景按表选角色。

| 用途 | Harmony Token / API 26 名称（均加 `sys.color.`） | 已迁移 app 色 / 新组件规则 |
| --- | --- | --- |
| 主字、次字、辅助 | `font_primary / font_secondary / font_tertiary` | `text_primary / text_secondary / text_tertiary`；`code_text,message_action_text` 用主字，`chat_text_secondary` 用次字 |
| 输入占位 | `font_fourth` | `text_placeholder`，不要拿来显示必要说明或错误 |
| 页面 / 卡面 / 中性控件 / 代码底 | `background_primary / comp_background_primary / comp_background_secondary / background_tertiary` | `bg_page / bg_card / bg_chip / bg_code`；`task_list_group_surface,task_list_menu_surface,composer_surface` 为卡面 |
| 分隔线与边缘 | `comp_divider` | `border,message_action_border,chat_header_divider,chat_bubble_border,composer_border` |
| 通用强调、插入光标 | `brand`（鸿蒙资源的命名，不是 Cindy 品牌色） | `accent,chat_input_caret`，存量通用入口 |
| 链接 / 高亮字、选中容器、键盘焦点 | `font_emphasize / interactive_select / interactive_focus` | 新组件按用途选择，存量共享 accent 不在本批拆调用点 |
| 主操作底与其上前景 | `comp_background_emphasize / font_on_primary` | `chat_cta / chat_cta_text`，两者成对使用 |
| 危险 / 警告 / 成功 | `warning / alert / confirm` | `danger / warn / success`。此处 warning 为平台一级警示（红），alert 为二级警示（橙） |
| 运行/协同指示 | `alert` | `chat_status_accent`，保留运行/协同语义，须有文案/图标，不能仅以橙色与警告区分 |

以下是保留的 HEX / 平台能力暂未可替代项。值按 Light / Dark 顺序，适用范围不得扩大。

| app 色或内容角色 | 固定值或回退 | 原因 |
| --- | --- | --- |
| `start_window_background` | `#FAECDD / #241C18` | 启动窗口属于品牌面，橙点限品牌资产使用 |
| `overlay / task_list_overlay` | `#66262626 / #73000000`、`#59262626 / #73000000` | 旧自绘遮罩，后续迁原生弹层遮罩，不按相近颜色改透明度 |
| `message_action_surface / chat_header_surface` | `#F6F6F6 / #803B3B3B`、`#E6F8F8F6 / #CC1F1F1E` | 旧动作层和半透明标题底；页迁移时改系统材质而非冒充不透明卡色 |
| `composer_glass_surface / composer_control_surface / composer_hairline` | `#E6FFFFFF / #E62C2C2A`、`#99FFFFFF / #993C3C3A`、`#59D7D7D4 / #593C3C3A` | 输入区现有玻璃材质的配对回退，保留 alpha 层次 |
| `chat_fab_surface / chat_fab_border` | `#CCFFFFFF / #CC2C2C2A`、`#59D7D7D4 / #593C3C3A` | 悬浮回退，待页面跟宿主材质收敛 |
| `chat_overlay_surface / chat_overlay_text` | 两态 `#E6000000 / #FFFFFF`（底/前景） | 图片等媒体覆盖层保持深底配浅字，禁用作一般 UI |
| `usage_chart_teal`、`usage_chart_pink`、`usage_chart_purple`、`usage_chart_other`、`usage_quota_plenty` | `#53a89d / #75bfb4`、`#df83b0 / #e79fc1`、`#ab7bc6`、`#969696`、`#14B8A6 / #2DD4BF` | 数据分类和额度刻度，不是操作色。分类与操作、警告语义分离 |
| `usage_chart_blue`、`usage_chart_amber` | `#3568BA / #80ACF6`、`#986018 / #F4B75C` | R15 独立数据系列颜色，选择仍以勾选标记表达，不跟随系统 brand 或告警色 |
| 文件批注墨色、品牌/来源图形 | 内容资产现有值，批注 `#ec4747` | 是输出内容/图形身份而非界面危险色，不随状态色替换 |

### 2.2 字阶和间距

自定义字阶使用 `UiKit.ets` 的显式 `fp` 或对应已核实的 `sys.float.*`，不要在开发侧叠乘系统的字号缩放。原生组件按默认字阶。深浅两态使用同一字阶，颜色分开映射。正文优先 ArkUI 默认行高，必须自定义时随 fp/字体一同伸缩，容器靠内容撑高并验证末行。原 `uiFontSize` / `uiLineHeight` 仍接受数值并取整、保留 8/10 的下限，不再乘 0.84。仅作为旧调用桥接，不试图从一个裸数字猜标题或正文。本批不改既有页面的字重、定高或调用点。

| 文本用途 | 鸿蒙字阶 / API 26（`sys.float.`） | 共享 fp 回退 / 字重 |
| --- | --- | --- |
| 大页标题 / 区域标题 / 常规标题栏 | `Title_L / Title_M / Title_S` | `UI_FONT_TITLE_L/M/S` 30 / 24 / 20，Bold |
| 列表主标题 | `Subtitle_L` | `UI_FONT_LIST_TITLE` 18，Medium |
| 按钮 / 紧凑按钮 | `Subtitle_M / Subtitle_S` | `UI_FONT_ACTION / UI_FONT_ACTION_SMALL` 16 / 14，Medium |
| 正文 / 次要信息 / 提示 | `Body_L / Body_M / Body_S` | `UI_FONT_BODY / UI_FONT_SECONDARY / UI_FONT_HINT` 16 / 14 / 12，Regular |
| 说明 / 次要说明 / 图表刻度 | `Caption_L / Caption_M / Caption_S` | `UI_FONT_CAPTION / UI_FONT_CAPTION_SMALL / UI_FONT_CHART_LABEL` 12 / 10 / 8，Medium |

| 用途 | 鸿蒙角色及 API 26 | 应用 Token / 回退与模式 |
| --- | --- | --- |
| 紧贴 / 行内 / 同组 / 页边 / 区块 | `sys.float.padding_level2/4/6/8/12` 类别 | `UI_SPACE_TIGHT/INLINE/GROUP/PAGE/SECTION` = 4/8/12/16/24vp。宽屏页边取栅格和栏宽约束；两态同值 |
| 小控件 / 内容容器 / 卡片 | `sys.float.corner_radius_level4/6/10` 类别 | `UI_RADIUS_SMALL_CONTROL/CONTENT/CARD` = 8/12/20vp。原生组件不覆盖默认。旧 CONTROL、CONTAINER、PILL 保留为兼容别名；胶囊取控件半高，兼容常量 999vp 由边界夹限 |
| 深度与材质 | 系统深度 / HDS 材质，ArkUI `ShadowStyle` 与原生组件默认 | 不给常驻卡片套浮层阴影，仅真实浮层使用系统阴影；材质不可用时回退配对表面+分隔色，亮暗各验 |
| 标准 / 紧凑操作图标 | 系统 HMSymbol（`sys.symbol.*`）优先 | `UI_ICON_SIZE_STANDARD/COMPACT` = 24/20vp 视觉目标。24vp 自绘操作基线 `UI_ICON_CUSTOM_STROKE` = 2vp，按比例缩放，不硬套到 HMSymbol、品牌图形或业务图表 |
| 图标按钮热区 | 系统 Button 原生互动与辅助语义 | `UI_TOUCH_TARGET_MIN` = 44vp，常用按钮宽高均从这档起。glyph 不等于热区，扩展区不得抢相邻控件，带可朗读动作名、focus 与按压反馈。分隔把手例外需有等效操作 |
| 动效 | 首选系统 Navigation、Menu、Sheet、原生按压和系统偏好 | 自绘反馈 80ms、轻量显隐 150ms、布局 200ms、加载循环 1000ms，两态同值；`UI_MOTION_*_MS` 在 UiKit，保留旧名称。入场 EaseOut、退场 EaseIn、布局 EaseInOut，跟手不补间，弹性复位单独核对。没有通用 250ms 档。减弱动效时用轻淡入或立即完成，不影响状态提交 |

## 3. 组件选型表

先用系统组件的焦点、按压、选中、无障碍、深浅色和系统字号。封装只固定 Cindy 的语义、Token、状态输入和本地化文案，业务回调仍归调用方。仅在系统组件无法表达既定语义、内容槽或大屏状态时自组，并保留等效的触控、键鼠和读屏操作。没有额外语义就直接用原生，不为每种控件另造一个组件。

| 场景 | 原生首选与薄封装 | 存量迁移和允许的例外 |
| --- | --- | --- |
| 页面标题栏 | HdsNavigation/HdsNavDestination 原生 title，统一入口 `UiNavigation`；内嵌和选项面板用 `UiPanelHeading`（SubHeader） | 首页、任务、新建保留已有 HDS 壳，用左侧原生 title 替换居中 builder。不要为一个标题另建嵌套路由。编辑/选择/页签语义分别考虑 EditableTitleBar / SelectTitleBar / TabTitleBar，不拿来模拟通用标题栏。 |
| 一级、二级和危险按钮 | Button + EMPHASIZED / NORMAL / ERROR，`UiActionButton` | 替换各页不同样式的主次动作。危险色不替代 Cindy 的风险确认，成功与失败文案由调用处提供。异步真实进度可直接用 ProgressButton，不模拟百分比。 |
| 图标按钮 | Button + HMSymbol，`UiIconButton` | 替换 ChatIconButton 和各页透明圆按钮，44vp 是命中区。只用图标仍需本地化的行动名称，调用方可补禁用原因。 |
| 列表行 / 分组标题 | List/ListItem/ListItemGroup + ComposeListItem，`UiListRow / UiListGroup`（SubHeader） | HarmonySettingsRow/Group 调用迁移时换公共组件，当前先并存，不修改调用方。复杂任务行保留业务内容，需原生横滑操作可选 HdsListItem；整行与尾部独立动作要分别确认读屏和键盘。 |
| 卡片 | 列表专用卡优先 HdsListItemCard，任意内容容器用 `UiCard` | 用量或设置卡可逐步收敛，图表等保留自有内容；不叠加系统样式已有的阴影。 |
| 空状态、异常 | ExceptionPrompt 用于异常，`UiInlineError`；`UiEmptyState` 用原生 Text/Button 组合 | 空不等于错，说明下一步；错误重试由调用方在可恢复时提供，别将既有空态一起换成告警。 |
| 分段控件 | CapsuleSegmentButtonV2，`UiSegmented` | 替换 ChatSegmented。调用方控制选中索引，组件管输入和原生选中动画。不要用 Tabs 实现同一区域的短筛选。 |
| 搜索框、表单编辑 | Search / TextInput | 任务搜索直接使用原生 Search，普通输入使用 TextInput；保留搜索提交、清除与键盘行为。 |
| 开关 | Toggle(Switch) | 设置/伙伴/群聊开关保留原生语义；不要用颜色模拟开关状态。 |
| 标签与筛选 | Chip / ChipGroup、Filter | 可选 Chip 用原生选中，静态标签不做按钮。多个独立维度可用 Filter；复杂任务筛选仍可依弹层标准使用选择表单。 |
| 底部工具栏 | HdsActionBar / ToolBar；一级导航 HdsTabs | 通用操作栏与底部页签区分；不会用固定 ToolBar 替代含编辑、发送、锚定面板的 composer。 |
| 分栏容器 | 普通列表详情可用 Navigation Auto / HdsSideBar；本首页保留 TaskSplitLayout 与 `UiSplitHandle` | 两个自定义分隔在迁移时接入等效单击菜单、焦点与键盘步进。视觉 SplitHandle 保留。详情布局外壳不因三栏而改用 SplitLayout。见下节评估。 |
| 下拉刷新 | Refresh | 有刷新语义的列表优先系统控件，调用方继续控制刷新请求和并发，不能因为页面上拉而偷换成轮询。 |
| 操作菜单、底部表单、确认框、轻提示 | [现有弹层标准](./overlay-standard.md) | 沿用 UiOverlay。工具提示用 bindTips；若结果确需要立即执行另一个非危险动作，评估 HdsSnackBar，不替代纯轻提示或确认。 |
| 锚定提示/输入面板 | 短提示用 bindPopup，复杂内容可用原生 Popup/自定义 Builder | 输入区域自定义仅在锚定与上下文保持必须时允许，编辑/列表仍原生；不拿它代替确认。 |

会话详情保留 HDS MINI 外壳和左对齐的自定义标题槽。原生标题有主/副文案和菜单槽，但没有将伙伴头像、标题最小宽度、会话状态字色、分栏返回/展开和 Worker 滚轮组合在同一标题栏的契约。窄栏或放大字号时，项目文件夹移入更多操作，为标题保留空间。普通新建任务页不需要这些插槽，使用 HDS 原生标题与返回。

### 3.1 API 26 工程核对

本工程为 API 26 Stage。下表路径相对 SDK 的 `default/`。高级组件实际声明多数是 **.d.ets**，由对应 kit .d.ts 转导出。表中的版本为组件最早 SDK 声明或官方版本，较新的重载、Stage/设备或跨平台支持可另有起始版本。已核实符号与声明，不把它当作本批构建已通过。

| 组件 | 最早 API 与声明证据 | 本工程接入 |
| --- | --- | --- |
| SegmentButton / CapsuleSegmentButtonV2 | 11 / 18，`openharmony/ets/api/@ohos.arkui.advanced.{SegmentButton,SegmentButtonV2}.d.ets` | `@kit.ArkUI`，优先受控的 V2 |
| ComposeListItem / SubHeader | 10 / 10，同路径 `{ComposeListItem,SubHeader}.d.ets` | `@kit.ArkUI`；ComposeListItemV2 为 26，不是行迁移前置条件 |
| EditableTitleBar / SelectTitleBar / TabTitleBar | 10，各自同名高级声明 | `@kit.ArkUI`，限定对应语义 |
| ToolBar / Chip / ChipGroup | 10 / 11 / 12，各自同名高级声明 | `@kit.ArkUI`，不混用 Web 版 toolbar |
| ExceptionPrompt / Filter / ProgressButton | 11 / 10 / 10（SDK 历史声明，下同；SDK 当前声明块对应 12 / 22 / 22），各自同名高级声明 | `@kit.ArkUI`；本批异常样式使用 PromptOptions 的最小子集 |
| FoldSplitContainer / SplitLayout | 12 / 10（SplitLayout 的当前声明块为 22，官方手机文档覆盖 12+），各自同名高级声明 | `@kit.ArkUI`；前者适合折叠分区，后者是图文内容模板 |
| Popup / Dialog / DialogV2 | 11 / 10 / 18，各自同名高级声明（本 SDK ConfirmDialog 类型当前块标 18，V2 从 18 起） | `@kit.ArkUI`，正常弹层按项目标准选 API |
| HdsNavigation / HdsTabs | 18 / 20，`hms/ets/kits/@kit.UIDesignKit.d.ts` 与 HMS 编译器 `build-tools/ets-loader/components/{hdsnavigation,hds_tabs}.json` | `@kit.UIDesignKit`，已经用于现有页面 |
| HdsSideBar / HdsActionBar / HdsSnackBar / HdsListItem / HdsListItemCard | 均 20，`hms/ets/api/@hms.hds.{HdsSideBar,HdsActionBar,HdsSnackBar,HdsStyle}.d.ets`（最后两项在 HdsStyle），以及同 UIDesignKit 出口 | `@kit.UIDesignKit`，注意官方设备能力范围 |
| Button / Toggle / Search / TextInput / Refresh | 7 / 8 / 8 / 7 / 8，`openharmony/ets/component/{button,toggle,search,text_input,refresh}.d.ts`；ButtonStyleMode 11、ButtonRole 12 | 声明式全局组件，不额外 import |
| List / ListItem / ListItemGroup / Menu | 7 / 7 / 9 / 9，`openharmony/ets/component/{list,list_item,list_item_group,menu,menu_item}.d.ts` | 声明式全局组件 |
| bindMenu / bindSheet / bindTips / 键盘与悬停 | bindMenu 7（受控重载 11）/ 10 / 19，`openharmony/ets/component/common.d.ts`；KeyCode 在 `openharmony/ets/api/@ohos.multimodalInput.keyCode.d.ts` | 全局修饰器，KeyCode 从 `@kit.InputKit` 引入 |
| 对话框与 Toast | `openharmony/ets/component/{alert_dialog,custom_dialog_controller}.d.ts`，`openharmony/ets/api/@ohos.arkui.UIContext.d.ts` 的 `UIContext.getPromptAction`（10） | 项目用上下文的 PromptAction，不新增其他全局调用方式 |

DevEco 文档依据：[系统预置 UI 组件库](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/system-preset-ui-component-library)、[HDS 组件](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ui-design-arkts-component)；CLI 读到的条目包括 HdsNavigation、HdsTabs、设置列表卡片样式、ComposeListItem、SegmentButtonV2、弹出框概述与折叠屏悬停态。

### 3.2 FoldSplitContainer 评估

**不作为首页双／三栏的替代容器。可以考虑仅在半折特定场景做小范围原型。** [FoldSplitContainer 官方参考](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ohos-arkui-advanced-foldsplitcontainer)说明主区、次区、可选扩展区，主要/次要区域按高度比上下排列，扩展区可以贯穿上下或位于其一侧。宽度 ≤600vp 的默认布局还是二分栏，并非 Cindy 要的单栈。宽度 >600vp 的横屏半折可进入悬停，上屏展示、下屏操作，并避让折痕，悬停可隐藏扩展区。

- API 的比例能配置，不等于有两条独立横向 resize rail。SDK 未提供拖拽手柄、每栏最小宽/约束、双阈值越限、拖动取消或“还原原宽”行为。无 Worker 全幅/返回栈或任务开合状态交接契约。直接套用会丢单栈与并排三列，或者反过来在系统容器内重造整套现有状态机。
- 2A 保持 TaskSplitLayout 等窗口和状态计算。除非半折真机证实有明确的“读内容/在下方操作”需求，暂不引入 FoldSplitContainer。原型即便成功也只在符合系统横屏半折条件的子场景使用。任务、草稿、Worker、宽度偏好和焦点置于外层，退出姿态不重建业务状态。
- SplitLayout 是主图/三段文案/内容 Builder 的自适应模板，不提供任务主从导航或拖动。普通页可用系统 Navigation 分栏、侧边栏，不能用模板替代任务首页。
- `UiSplitHandle` 保留原把手动画并用系统 Button 承载可朗读标签、焦点、键盘方向步进、Home/End、Enter/Space/鼠标或单击菜单。离散步进只夹限，不触发全幅。菜单单独暴露两侧全幅或返回的本地化动作。父级继续拥有拖动、越限、可见状态及焦点回归。2A 接入时保证父级轨道和中央按钮不互相拦截，并实机测菜单开关与 TalkBack。旧 `SplitHandle` 继续只装饰，现有页面不改变。

## 4. 窗口与折叠形态

宽档按 SDK `WidthBreakpoint`，以窗口而非物理屏幕型号判定。宽档是组件样式输入，实际栏数另算**扣除系统避让、折痕和栏间保留区之后的可用空间**。当前 `TaskSplitLayout` 仍用 viewport≥600、安全宽≥760、安全高≥480；以下规则随多设备迁移实现，本批不改页面状态机。

| 窗口宽档 | 常态目标 | 切换条件 |
| --- | --- | --- |
| xs <320 / sm 320–<600vp | 单栏，外屏优先完整可用 | 任务列表与当前详情走单栈，协同通过独立可返回的呈现；不因折叠态牺牲主要操作 |
| md 600–<840vp | 单栏或列表＋详情 | 维持安全宽至少 760、安全高至少 480 的基线。列表至少 300、详情至少 400vp。短窗、系统分屏/浮窗继续单栏 |
| lg 840–<1440vp / xl ≥1440vp | 待空间与任务状态足够时双/三栏 | 列表 300–420vp，普通详情至少 400vp。有 Lead、打开协同、设备非折叠且详情区至少 648vp（Lead / Worker 各 324vp）才三栏。保留列表时理论下限 948vp，实际按列表宽与可用区计算。空间不足可收列表给 Lead＋Worker，或降为单栏，不压缩至不可读 |

- **折痕 / 半折悬停**：读取姿态和可用折痕几何，禁止把主要操作、文本和拖动命中区放在不可用折痕上。垂直折痕可作为不可拖的天然分隔，前提是两侧分别够宽。水平半折只有实际窗口姿态和空间合适才将内容/操作分区，否则退回可用的窗口布局。鼠标 hover 与设备悬停是两件事，键鼠不依赖拖动手势完成同等操作。
- **横竖屏、系统栏、键盘**：跟随窗口变化并更新 system、cutout、navigation indicator 与 IME，统一 px→vp，背景可延伸、交互内容须避让。键盘不参与栏数断点，单栏系统避让，双/三栏当前输入所在栏避让；附着面板随可用区域更新。旋转和折展不重复叠加底部 inset。
- **手势增强**：保留主分隔条拖到底进入列表独占/详情全幅，Worker 分隔条越限展开/返回，以及显式协同展开。常态偏好与越限预览分离，返回先恢复分栏、再收起协同。提供可见、可聚焦的非拖动入口。伙伴紧凑模式仅变密度，保持伙伴身份、顺序、状态、入口与用户偏好。

| 开合或换壳状态 | 须保留及降级 |
| --- | --- |
| 任务与阅读位置 | 保留设备/任务标识、可用消息定位和优先可见内容。不重复推页，不回任务列表重选。 |
| 草稿 | 保留当前任务/新建关联的已录入文字与已接收附件；不要将正在录音或未提交的输入法组合标记误当已保存。 |
| 协同 | 保留选中 Worker、打开/展开意图。窄屏用可返回的单栏呈现，重新宽屏恢复可用的分栏/全幅，不跨任务串状态。 |
| 拖动宽度 | 记住常态希望的宽度/比例，按新窗口夹限，恢复到原形态时恢复可用尺寸。不要持久化手势未松手的预览，不新增跨进程偏好。 |
| 焦点 | 保留当前可见控件的语义焦点与选区，目标消失时退到最近的有效入口。不因折展擅自弹起键盘，不将焦点留在隐藏栏。 |

首页保留列表独占、详情全幅的意图和同一详情实例。窗口高度不可读时沿用最后一次不含键盘的安全高度，尚无有效读数则保持单栏。退出双栏的安全高度为 480vp，重新进入需要 492vp。横向折痕只有处于半折且至少一侧可用高达到 280vp 时才启用单侧布局，平放和数据不足时不强制截半。

同一首页实例内，仍可见的输入和协同控件不主动重置焦点。搜索或分隔条被隐藏时，焦点可回到范围按钮或详情容器。独立详情换壳以及 Worker 原焦点、编辑选区的精确恢复由详情侧语义交接决定，未拿到目标时不恢复输入焦点，也不主动弹键盘。

## 5. 验收与本批风险

- 资源验证先编译一次，确认 color JSON 系统别名可解析，特别是系统默认主题与应用限定词的叠加。真机覆盖浅/深冷启动与运行中切换。核对启动背景和图标衔接、主按钮底/前景、置灰文本、选中与光标、用量图例、危险/成功/提醒和有采样材质的叠层。不要用某一套硬编码蓝模拟通过。
- 字号风险优先查外屏会话标题动作组、模型行/服务商段和强度按钮、composer 固定高度及附件条、协同标签轮、伙伴紧凑条、聊天分段与设置尾部、代码/富回答固定行高。长中英模型名、放大字体、两行标题和 IME 同开时重点看裁切、热区重叠、滚动能否看到整项。批次 0 不改这些定高和布局。
- 在同一任务覆盖外屏→内屏→外屏、三栏→双/单栏→三栏、分隔条越限与取消、协同全幅及返回、草稿/附件/键盘仍在时折展；补验直板、平板、横屏、短窗、分屏、悬停、TalkBack、键鼠拖动及焦点恢复。
- 页面迁移后以真机截图和 UI 树为验收证据，不能以静态 Token 对照替代。批次 0 的交付只是源码/资源静态检查，不包含构建或设备测试。
