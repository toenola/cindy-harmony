# Harmony v1.3.0

> 状态：开发中
>
> 开发分支：`feat/v1.3.0`
>
> 目标平台：HarmonyOS 7.0 / API 26+

## 版本目标

本版先完成 Mobile 已有能力在 Harmony 的等价落地，再集中做一次构建、Local Test
和设备验收。核心功能包括付费模型权限、工具结果压缩提示、模型运行时状态投影、裸
URL 自动识别，以及设置页的信息架构和视觉对齐。

Harmony 独有的 Huawei Push Token 仍沿用原有业务链路，本版只把它放入与 Mobile 相同的
“通知”分组并统一样式，不改 token 获取、刷新、保存和推送开关语义。

## 资料索引

- [设置页对齐清单](./设置页对齐清单.md)
- [开发计划](./开发计划.md)

## 验证边界

本版只修改和验证 `apps/harmony`。Harmony 当前没有 Mobile 的 Expo OTA、Beta 渠道、
TapDB 统计 SDK 和多语言资源，因此设置页对这些能力展示诚实的等价状态，不伪造不可用
的操作入口。
