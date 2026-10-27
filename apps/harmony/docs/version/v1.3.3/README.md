# Harmony v1.3.3

> 状态：独立 review 问题已修正，展开横屏 Light / Dark 核心回归通过；其余设备范围见文末
>
> 评估日期：2026-10-21；开发日期：2026-10-22
>
> 开发分支：`feat/v1.3.3`

## Git 基线

- 从 `feat/v1.3.2` 的 `167e7e108` 创建本分支。
- 上次上游基线：`ebded1721`（2026-10-12）。
- 本次拉取的上游快照：`3482d51f4`（提交时间 2026-10-21 13:54:56，UTC+8）。
- 上游合并提交：`fdc73c434`，无冲突，带 DCO `Signed-off-by`。
- 上游区间没有修改 Harmony；合并后 Harmony 跟踪文件与 `feat/v1.3.2` 一致，本机签名配置未改写。

## 本期范围

按 [Mobile 差异评估](./Mobile差异评估.md) 的建议顺序完成 A1 兜底 → A2 → A3 → A1 原生渲染。

| 项 | 用户可见结果 | 主要代码（相对 `entry/src/main/ets`） |
|---|---|---|
| A1 富组件回答 | assistant 回答中的 ` ```cindy-ui ` 围栏原生渲染为文字 / 标题 / 图标 / 布局 / 统计 / 柱状与折线图 / SVG / 输入 / 滑块 / 开关 / 选择 / 按钮 / 表单 / 折叠 / Tabs；Markdown、代码、公式、图片节点复用正文 Markdown；复制与分享导出为可读文本；富组件回答始终算交付正文 | `core/messages/RichAnswer.ets`、`RichInteractionMemory.ets`、`components/RichAnswerView.ets`、`MessageRender.ets`（`richParts`）、`pages/TaskPage.ets`（`richAnswerBody`） |
| A2 Codex 超快速度 | 读取 Host 的 `fastModeTier` 编码；发送、`maker:set-fast-mode`、Agent 切换、新建任务默认值都原样回传 `'ultrafast'`；Codex 模型声明支持时，模型行速度从开关变为 标准 / 快速 / 超快 | `core/tasks/ModelSpeed.ets`、`TaskModels.ets`、`InputQueueStore.ets`、`MessageStore.ets`、`SessionAgentSwitch.ets`、`NewSessionRuntimeDefaults.ets`、`components/ComposerModelOptionRow.ets`、`TaskPage.ets`、`NewSessionPage.ets` |
| A3 消息呈现 | 失败采样输出折进工作过程并提示「此回复未完成」；工具原生过程媒体留在所属步骤，结果文字剥掉展示信封；生图交付失败可重试（`maker:images:retry`）；MCP App 来源标签与服务器 ID | `core/messages/ToolProcessMedia.ets`、`MessageRender.ets`、`MessageSourcePresentation.ets`、`TaskPage.ets`、`TaskScrollState.ets` |

有意差异与无需移植的部分见 `docs/decision-log.md` D-011、D-012。

## 厂商信息获取边界（2026-10-22）

- 鸿蒙禁止直接调用模型厂商或 Agent 厂商接口获取信息，统一通过 Device Link 从电脑端获取；电脑端负责厂商通信与认证，不把厂商凭证下发到鸿蒙。规则正文见开发指南第 1 节与决策 D-013。
- 经用户确认，保留会话详情更多菜单中的「账户配额与用量」。现有链路为 Harmony 请求 Desktop 的 `maker:usage:account` / `maker:usage:codex-rate-limits`，由电脑端读取账号限额或刷新厂商用量接口，符合上述边界；电脑端代查不等于鸿蒙直连。
- 「暂不可用」是无有效投影数据时的统一占位，可能来自不支持的来源、无数据、限额窗口过期或读取失败，不表示鸿蒙直接调用厂商失败；账户额度也不等同于任务自身的 Token / 上下文消耗。
- 已撤回临时的入口删除，保留原有投影、定时刷新、资源与两项单测；未改动 Desktop、Mobile 或共享协议。

## 独立 review 修正（2026-10-22）

- 分享图改为冻结富组件当前的可见子树和本机控件值，排除收起的 details 与未选中的 Tab 正文；整条消息复制仍保留完整可读内容。
- sessions patch 显式携带 fastMode 时整体替换速度档，不再继承旧的 ultrafast tier；无关字段更新仍保留速度。
- 原生文字、按钮、选项与说明通过 Builder 内调用的取值回调读取当前状态，避免按值参数令流式 patch 标签停留在旧值；控件身份保持不变。
- YouTube 查询参数容错解码，异常百分号编码降级为不带起播时间的观看链接，不中断回答渲染。
- 本机视图值直接序列化已转义的键值，保留合法的 __proto__ 绑定；继续读写原有 version 1 格式，不迁移或清空既有数据。
- 真机深色验收额外发现 Canvas 仍读取浅色资源：改用 getOverrideResourceManager() 匹配当前系统资源，并使用 Configuration 通知参数和回前台同步触发重绘；不新增硬编码深色补丁。

### 回归测试依据

| 测试文件 | 生产入口与结果 | 旧覆盖缺口与最小失败输入 | tier |
|---|---|---|---|
| V133Speed.test.ets | TaskStore.handleSessionsPush → InputQueueStore.enqueueText，降档后实际发送普通快速 | 原测试仅覆盖完整快照；超快任务收到仅含 fastMode:true 的 patch 后残留旧 tier | unit，内存 Store 和发送 fake |
| V133RichAnswer.test.ets | freezeShareProjection 排除隐藏正文并冻结当前本机状态；视频转换不抛错；RichInteractionMemory 落盘重载不丢绑定 | 原测试只有普通文本分享、合法 URL 与普通绑定；新增收起 details / 非当前 Tab、t=% 和 __proto__ 的最小输入 | unit，真实解析与投影入口，内存存储 |

先在修复前运行回归，确认四个逻辑问题失败，再修复实现；原生标签的实际刷新另在设备验收，不以源码字面量测试替代。最终 Harmony 全量 454 / 454 通过，整轮 Hvigor 耗时 4.613 秒；新增用例无真实等待或外网调用。

### 本轮真机验收（2026-10-22）

- HUAWEI Pura X Max，HarmonyOS 7.0 / API 26，展开横屏双栏；使用现有签名配置生成 signed HAP 并覆盖安装，未卸载或清数据。
- 在现有 Render test 中追加专用回答：先创建旧标签，追加 20 个隐藏 divider 操作后再 patch；按钮、details、两个 Tab 与 select 选项均显示 patch 后的标签，切换 Tab 正常。
- 滑块从 3 调到 8，统计从 60 实时变为 160；点击 patch 后的按钮恢复 3 / 60。
- 保持 details 收起并选中第二个 Tab，仅选择该 assistant 消息生成分享预览：包含第二个 Tab 当前正文，不包含 details 隐藏正文或第一个 Tab 正文；有折叠内容提示。仅预览并取消，没有向其他应用发送。
- 编辑绑定为 __proto__ 的输入，调整滑块为 8，选中第二个 Tab；退后台、停止应用进程并重新启动后，三项状态均保留。
- 异常百分号视频链接正常显示打开入口，未中断后续呈现；未打开外部站点。
- 修复 Canvas 浅色资源误用后，已目检 SVG、折线、刻度与网格的 Light / Dark；同一条已打开回答往返切换模式无需重启或重新生成，颜色正确。验收后恢复原浅色模式。
- 最终 devecocli build 通过，signed HAP 已再次覆盖安装；仅在 apps/harmony 内执行验证。

## 首轮开发验证

- 单测：`entry/src/test/V133RichAnswer.test.ets`、`V133Speed.test.ets`、`V133Presentation.test.ets`；Harmony 全量 451 / 451 通过（基线 434）。富组件的期望值由共享 `richAnswer.ts` 对同一输入实际运行得到。
- 构建：`assembleHap` 通过，生成 `entry-default-signed.hap`。
- 真机（2026-10-22，USB 真机 `6HR0…0343`，展开横屏双栏，Light 模式）：signed HAP 覆盖安装，未卸载、未清数据。
  用 Codex 生成一条覆盖全部组件类型的 `cindy-ui` 回答实测：
  - 标题、滑块、统计、输入、开关、单选、两列网格、柱状图、折线图（刻度 / 横轴标签 / 数值）、SVG（`primary` / `success` 角色色）、
    Markdown 列表与加粗、代码块、Tabs、折叠、按钮均原生渲染；Markdown / 代码经 `@BuilderParam` 跨递归组件传递正常。
  - 拖动滑块时统计值与引用它的网格统计即时联动（6 → 19 → 4，Total 120 → 380 → 80）；输入框连续输入不丢焦点；
    Tabs / 单选高亮跟随点击；折叠展开正常；Reset 按钮把月数恢复为 6。
  - 覆盖安装并重启应用后，滑块与输入值从本机存储恢复。
  - 真机首测发现并修复：`@Builder` 普通参数按值传入，计算型文字与选中高亮不随状态刷新；改为在 builder 内读取状态，
    Markdown 段以内容签名作 `ForEach` key。
- 未在真机验证：
  - Dark 模式未目检（含 Canvas 重绘）。
  - 超快速度界面：该电脑上所有 Codex 来源（XD Gateway、sub-openai、中转站）的模型都未声明 Fast，速度控件按设计不显示；读写往返由单测覆盖。
  - 失败采样折叠、工具过程媒体、生图交付重试：无法按需触发，由单测覆盖。
  - 窄屏手机形态与折叠态。
- 本机模拟器均为 HarmonyOS 6.1.1（API 24），低于工程 API 26 基线，无法用于验收。

## 剩余设备验收范围

1. 有官方 OpenAI（支持 Fast / Ultrafast）的电脑上：模型行出现 标准 / 快速 / 超快；超快任务在 Harmony 发消息、切模型后桌面仍显示超快。速度增量更新后的实际发送字段由回归单测覆盖。
2. 窄屏、折叠态，以及 row / grid 退为单列。
3. 失败采样折叠、工具过程截图与生图交付失败重试的真实链路。

## 资料索引

- [Mobile 差异评估](./Mobile差异评估.md)：上游更新、兼容缺口、可选增强和独立能力划分。
