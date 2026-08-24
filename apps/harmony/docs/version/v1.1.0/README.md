# Harmony v1.1.0

> 状态：开发完成，候选发布受阻于设备环境（见验收与发布状态）
>
> 基线分支：`feat/v1.0.0`
>
> 开发分支：`feat/v1.1.0`
>
> 基线提交：`d5428108d`
>
> 目标平台：HarmonyOS 7.0 / API 26+

## 版本目标

v1.1.0 跟进本次官方 Mobile 变更中对 Harmony 有价值的全部能力，并按 HarmonyOS
系统能力、ArkUI 交互和当前 Device Link 契约完成原生实现。唯一明确排除项是 CAPTCHA。

“全部跟进”按以下口径执行：

- 跨端业务语义和可靠性修复：在 Harmony 运行时代码中实现。
- Mobile 特有框架或系统能力：交付 Harmony 等价方案和验证，不移植 Expo、React Native、
  Metro 或 iOS 专属 API。
- 依赖外部 SDK、发布平台或服务端契约的事项：先完成客户端边界、适配层和可验证降级；
  外部条件未满足时不得伪造成功，并在候选发布前明确阻塞状态。

## 范围摘要

1. 修复消息计划归属、工作时长、权限提示和 Pi slash 展示。
2. 补齐发送贴底、队列触控、模型信息布局和附件首条标题。
3. 让 Pi 命令 / Skill 清单按当前任务绑定，并遵循远端默认模型标记。
4. 建立实时 push authority fence、自动化任务缓存策略和全局消息内存预算。
5. 拆分 Device Link 普通稳定窗与 1013 拥塞稳定窗。
6. 新增 Harmony 原生“会话生成图片并分享”。
7. 建立 Harmony beta / release 版本交付口径、可选安全观测身份适配和 DevEco
   模拟器安全运行流程。
8. 验证 Harmony 系统选图器的受限授权与 URI 生命周期。

## 明确不做

- CAPTCHA 登录校验及相关 token、页面和协议接线。
- 为了复刻 Mobile 工具链而在 Harmony 工程引入 Expo、React Native、Metro 或 iOS API。
- 未经协议事实源确认新增跨端 wire 字段或私自宣称可靠传输能力。
- 修改 `apps/mobile`、`apps/desktop`、共享 packages 或服务端。

## 资料索引

- [开发计划](./开发计划.md)
- [Mobile 差异评估](./Mobile差异评估.md)
- [技术设计](./技术设计.md)
- [平台等价交付记录](./平台等价交付记录.md)
- [验收与发布状态](./验收与发布状态.md)
- [交接清单](./交接清单.md)：接手开发的待办、阻塞与代码缺口

## 发布完成定义

- [ ] 开发计划中的运行时能力、平台等价项和回归项全部完成。
- [x] CAPTCHA 保持未接入，且没有残留半成品入口或错误依赖。
- [x] `versionName`、`versionCode`、Device Link `appVersion` 和设置页版本一致。
- [ ] Harmony Local Test、完整 HAP 构建和 signed HAP 覆盖安装通过。（前两项已过，覆盖安装受阻）
- [ ] 关键场景在窄屏、展开横屏、Light、Dark 下完成真实交互验证。
- [x] 所有未满足的外部依赖均被明确列为发布阻塞，而不是静默降级后宣称完成。
- [x] 完整 diff 只涉及授权范围，并通过 `git diff --check -- apps/harmony`。
