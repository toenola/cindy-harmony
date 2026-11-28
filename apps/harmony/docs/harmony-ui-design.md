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
| `usage_chart_teal`、`usage_chart_pink`、`usage_chart_purple`、`usage_chart_other`、`usage_quota_plenty` | `#53a89d / #75bfb4`、`#df83b0 / #e79fc1`、`#ab7bc6`、`#969696`、`#14B8A6 / #2DD4BF` | 数据分类和额度刻度，不是操作色。少数图表项仍复用 accent / warn，批次 2 拆成独立图表上色 |
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

## 3. 组件选型

| 场景 | 首选 | 产品约束 |
| --- | --- | --- |
| 首页、详情、设置、新建 | HdsNavigation 标题栏及原生返回；首页保留 HdsTabs | 会话和伙伴名称位于左侧，返回之后是标题/副标识，尾部保留相关操作；面板标题与内容起点对齐。 |
| 任务、设置、目录和会话列表 | List/ListItem 与系统状态，可复用 HarmonySettingsRow 的信息槽 | 行使用标题、说明、状态、尾部动作；动态增高；紧凑态不改变内容优先级。 |
| 卡片、按钮、选择与表单 | ArkUI 卡面、Button、Toggle、TextInput，分段优先系统组件 | 主次明确，危险动作按 Cindy 后果与确认语义；分段不代替页面导航，去掉复制 iOS 皮肤的包层。 |
| 操作菜单、表单、确认与轻提示 | [现有弹层标准](./overlay-standard.md) | 继续用系统弹层和该文档的材质退回；标题靠左。 |
| 输入就地面板 | 原生编辑器、列表和可用材质组合成锚定面板 | 保留输入上下文、模型/权限/设备选择状态和返回逻辑；仅需要锚定关系时自组，不拿来替代系统确认。 |
| 空态、状态、媒体 | 文本＋系统状态组件；图片、业务图表和富卡按内容自定义 | 空态引导下一步，媒体不改原图颜色，数据和运行状态不能只靠颜色表达。 |

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

## 5. 验收与本批风险

- 资源验证先编译一次，确认 color JSON 系统别名可解析，特别是系统默认主题与应用限定词的叠加。真机覆盖浅/深冷启动与运行中切换。核对启动背景和图标衔接、主按钮底/前景、置灰文本、选中与光标、用量图例、危险/成功/提醒和有采样材质的叠层。不要用某一套硬编码蓝模拟通过。
- 字号风险优先查外屏会话标题动作组、模型行/服务商段和强度按钮、composer 固定高度及附件条、协同标签轮、伙伴紧凑条、聊天分段与设置尾部、代码/富回答固定行高。长中英模型名、放大字体、两行标题和 IME 同开时重点看裁切、热区重叠、滚动能否看到整项。批次 0 不改这些定高和布局。
- 在同一任务覆盖外屏→内屏→外屏、三栏→双/单栏→三栏、分隔条越限与取消、协同全幅及返回、草稿/附件/键盘仍在时折展；补验直板、平板、横屏、短窗、分屏、悬停、TalkBack、键鼠拖动及焦点恢复。
- 页面迁移后以真机截图和 UI 树为验收证据，不能以静态 Token 对照替代。批次 0 的交付只是源码/资源静态检查，不包含构建或设备测试。
