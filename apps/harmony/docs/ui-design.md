# Harmony UI 设计

> 状态：Draft

## 1. 设计目标

使用 ArkUI 原生组件和 HarmonyOS 交互习惯，同时保持 Cindy 的克制、低干扰视觉语言。

Harmony 端不是把 iOS / Android 页面原样搬过来，也不是把桌面端压缩成小屏。需要重新组织为适合鸿蒙触控、返回手势和系统窗口的原生页面。

## 2. 页面结构

一期页面：

```text
LoginPage
HomePage
TaskPage
Permission / Ask User / Plan Review
SettingsPage
```

任务详情主层固定为：

```text
Header
MessageList
Pending Interaction / Composer
```

队列、Payload、Diff、媒体详情、文件详情等按需进入 sheet 或全屏页面，不在消息主流中堆叠控制台信息。

## 3. ArkUI 原生组件

优先使用：

- Navigation。
- List / ListItem。
- Scroll。
- Text / Span。
- TextInput。
- Button。
- Dialog / Sheet。
- Image。
- LoadingProgress。

复杂 Markdown 或媒体内容可以局部使用 ArkWeb，不把 ArkWeb 作为整个应用的 UI 框架。

## 4. Cindy 设计系统约束

跨端可以复用 Cindy 的设计原则：

- Light / Dark 两种模式同时实现。
- 颜色通过语义 token，不直接散落硬编码颜色。
- 默认使用克制的中性色。
- 主要交互使用清晰的触控区域。
- 重点状态才使用语义色。
- 不使用无必要的阴影和渐变。
- 内容优先，减少解释性状态卡。
- 控件、容器和弹层使用统一的圆角层级。

具体 Cindy 设计规则以根目录 `docs/design-rules/DESIGN.md` 为准；Harmony 特有的系统组件和交互遵循 HarmonyOS 官方规范。

## 5. 资源复用

可参考并复制：

```text
apps/mobile/assets/login/
apps/mobile/assets/fonts/
apps/mobile/assets/icon.png
apps/mobile/assets/splash/
```

Harmony 构建资源放入：

```text
apps/harmony/entry/src/main/resources/base/media/
```

不建议用跨目录软链接作为正式构建资源。

## 6. 双模式验收

每个新页面和组件必须检查：

- Light 下文本、边界、按钮和状态对比度。
- Dark 下文本、边界、按钮和状态对比度。
- 禁用、选中、提交中、错误和断线状态。
- 系统字体放大后的布局。
- 小屏设备和折叠屏宽度下的溢出。
- 返回手势、弹层关闭和键盘遮挡。
