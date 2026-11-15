# Harmony v1.3.6

> 状态：四项功能已实现并安装到手机，待交互验收
>
> 评估日期：2026-11-12
>
> 开发分支：`feat/v1.3.6`

## 基线

- 从 fork 的 `feat/v1.3.5`（`3517f94f21`）创建分支。
- 上次上游基线：`ae7bd07215`（2026-11-09）。
- 本次上游快照：`4f3ff83522`（2026-11-12）。
- 合并提交：`1895229f24`，带 DCO；合并没有冲突。上游区间没有修改 `apps/harmony`。
- 本机签名配置仍为未提交的本地改动，不属于本版交付资料或合并提交。

## 当前结论

本期建议先处理异步提问的撤回与草稿连续性，再补项目迁移、跨电脑模型档位记忆和可远程确认的 Issue 卡。
这些是 Mobile 已有、Harmony 源码仍有明确缺口的行为。模型账号配额、消息来源、文件预览和搜索标签
列为后续验证或增强；伙伴群聊、Agent Net 等独立能力不随本次更新机械移植。

详见 [Mobile 差异评估](./Mobile差异评估.md) 和 [开发计划](./开发计划.md)。

四项能力已在 Harmony 实现：异步提问草稿保留及取消后补充发送、任务项目迁移、
按账号与远程模型保存 effort / Fast、可远程确认的 Issue 卡。已通过本地 Local Test 与
命令行签名构建，并使用签名 HAP 覆盖安装到已连接手机；尚未验收四项实际交互。

## 本机验证

- `hvigorw test --mode module -p product=default -p module=entry@default` 通过；测试日志未出现逐例错误。
- `devecocli build --modules entry@default` 通过，生成 `entry-default-signed.hap`。
- 2026-11-15，HDC 显示手机为 `Connected`；`install -r` 返回安装成功，`aa start` 返回启动成功并查到进程。
- 尚未验证 Light / Dark 实机外观和四项远端交互。
