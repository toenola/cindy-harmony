# 项目与资源接线（固定参考 91179cedad）

本目录是可调用的业务 Store，公共入口由集成人接入；未接线、未运行 Harmony 构建或真机验收，不能标为 E 整体交付完成。

## 公共接口

- `ResourceInvoke(deviceId, channel, args, timeoutMs?)` 返回 **unwrap 后业务数据**，失败抛出保留 `code` 的错误。适配器负责 `openLink`、同账号可控制设备检查、AppServices 的调用调度及 `DlInvokeOptions.timeoutMs`。不得给共享访客复用这个适配器。
- 创建 `ProjectStore(invoke)`、每台电脑一个 `ResourceStore(invoke)`；`configure(scope, deviceId, locale?, online)`：资源需 locale，项目无需。scope 必须包含账号/授权及连接代次；revoke 在撤权时同步清理，dispose 在所有者退出时清理。
- 接入 `ProjectSettingsPanel({store,projectKey,deviceName,title,create,labels,onChooseDirectory,onPickImage,onSaved,onClose})`。设置入口用完整 `local:` 或 `remote:<encoded SSH id>:<path>` 主机身份，不能传 `device:` 展示分组键。
- `onChooseDirectory` 必须固定目标电脑，复用远程目录服务/现有选择器；不得打开手机本地目录。SSH 项目组件不会调用电脑目录选择器。旧只读附加目录原样保留。
- `onPickImage` 接鸿蒙相册/裁剪转换，返回不超过 300 KB 的 PNG/JPEG/WebP data URI；取消返回空串。不接回调时上传按钮禁用，不假装上传可用。
- `onSaved(createdProjectKey)` 刷新 `taskProjectAliases` 与项目目录列表，以电脑回执的实际目录填入新建任务草稿；不自动发消息。v6 仅注册选择的已有目录，v7 支持自动目录和仓库。
- 接入 `ResourcesPanel({store,labels,onOpen})` 到公共右侧详情/合盖单栏容器。组件管理可见生命周期，无页面级新连接。`onOpen` 的 session 链接保留该 Store 的 deviceId；resource 链接保留完整 ref 并进入相应资源。导航效果也经该回调。
- `ResourceStore.markReadThrough(at)` 仅在关联任务同步完毕且实际看到该回复后调用；打开详情本身不清未读。当前只实现主伙伴 bot 的 host read state，无话题读位扩展。
- AppServices 已有 `sessions` topic 订阅：`maker:remote-resources:changed` 继续派发给原 roster，同时调用 `resourceStore.handlePush(deviceId,channel,payload)`；`local-db:project-aliases:changed` 同时调用 `projectStore.handlePush(deviceId,channel)`。已有订阅由公共层引用计数，不另建重复订阅。
- 注册单测：`ProjectsStore.test.ets` 默认导出 `projectsStoreTests()`；`ResourcesStore.test.ets` 默认导出 `resourcesStoreTests()`。Worker 未改 LocalUnit 注册、未执行测试/构建/安装。

## 流量和边界

可见打开/手动刷新/恢复只读当前电脑；资源 manifest、list（200条分页）、get 各按当前视图调用。每 Store 一个在途读、一个失效补读，push 300ms 合并；后台不读，无网络定时轮询，无自动写重试。项目 clone 写预算 360000ms，普通读写沿公共默认预算。单电脑错误不关闭共享连接；账号/设备/连接代次变更后迟到数据丢弃；撤权立即清空。资源 schema 描述不是授权，电脑仍复验每次动作。通用表单/富呈现保持不支持，仅渲染惰性 fallbackMarkdown（不执行 HTML/JS）。插件资源和已移除 routines 不进入发现结果。

## 尚未完成与真实协议缺口

- 官方 `set-project-info` 没有 operationId 或按创建操作查询状态接口。未知回执保留本进程 pendingProjectKey/repository，锁定重复写、允许读回 aliases，须用户在电脑确认后显式解除锁定。不能凭 aliases 同名项目证明某次 clone 完成；没有跨重启的可靠回查。不要另造查询 wire 或宣称已满足完整克隆幂等恢复。
- 当前图标 picker 提供固定快照的完整标准符号几何、五种 emoji、字母、默认和注入相册上传；颜色选择尚未实现；自动图标来源/查找中/无结果已展示。旧符号/颜色值保留，不默默降级保存；版本不支持彩色符号/字母时 Store 拒绝。
- 创建目录预览已按官方规范化文件夹名展示，重名编号以回执为准。粘贴仓库链接到名称处自动切来源已实现；SSH 手工附加目录输入已实现，目标电脑继续复验真实路径和授权。
- 资源详情用普通可复制 Text 呈现 fallbackMarkdown，尚未接现有 Markdown renderer；资源表单保持明确不支持，与普通 Mobile 资源详情一样不执行。搜索采用用户显式提交，不做输入逐字符请求。
- 所有缓存仅在内存。账号清理安全，但没有离线磁盘缓存/持久未读。项目表单监听 Store identity 变化，清空旧草稿并请求关闭；原生目录/图片结果也检查 identity，迟到选择不能写入新账号。
- 未执行 Harmony tests/Hvigor/lint/真机/签名验证；由集成人串行完成。构建失败不得改签名或弱化规则。

## 文案（交公共五语言资源，字段与两个 Labels 类同名）

| key | zh-CN | zh-TW | en | ja | ko |
|---|---|---|---|---|---|
| refresh | 刷新 | 重新整理 | Refresh | 更新 | 새로고침 |
| more | 加载更多 | 載入更多 | Load more | さらに読み込む | 더 불러오기 |
| back | 返回 | 返回 | Back | 戻る | 뒤로 |
| search | 搜索 | 搜尋 | Search | 検索 | 검색 |
| empty | 暂无内容 | 尚無內容 | Nothing here yet | まだありません | 아직 내용이 없습니다 |
| openTask | 打开任务 | 開啟任務 | Open task | タスクを開く | 작업 열기 |
| unread | 未读 | 未讀 | Unread | 未読 | 읽지 않음 |
| unsupported | 暂不支持 | 尚不支援 | Not supported | 未対応 | 지원되지 않음 |
| cancel | 取消 | 取消 | Cancel | キャンセル | 취소 |
| confirm | 确认 | 確認 | Confirm | 確認 | 확인 |
| name | 名称 | 名稱 | Name | 名前 | 이름 |
| directory | 项目目录 | 專案目錄 | Project directories | プロジェクトフォルダ | 프로젝트 폴더 |
| repository | 仓库链接 | 儲存庫連結 | Repository URL | リポジトリURL | 저장소 URL |
| local | 电脑文件夹 | 電腦資料夾 | Computer folder | パソコンのフォルダ | 컴퓨터 폴더 |
| computer | 电脑 | 電腦 | Computer | パソコン | 컴퓨터 |
| save | 保存 | 儲存 | Save | 保存 | 저장 |
| create | 创建项目 | 建立專案 | Create project | プロジェクトを作成 | 프로젝트 만들기 |
| addDirectory | 添加目录 | 新增目錄 | Add directory | フォルダを追加 | 폴더 추가 |
| remove | 移除 | 移除 | Remove | 削除 | 제거 |
| main | 主目录 | 主目錄 | Main directory | メインフォルダ | 기본 폴더 |
| icon | 图标 | 圖示 | Icon | アイコン | 아이콘 |
| reset | 恢复默认 | 恢復預設 | Reset | 初期設定に戻す | 기본값으로 복원 |
| upload | 上传图片 | 上傳圖片 | Upload image | 画像をアップロード | 이미지 업로드 |
| letters | 1–2 个文字 | 1–2 個文字 | 1–2 letters | 1〜2文字 | 1~2자 |
| discard | 放弃修改？ | 放棄修改？ | Discard changes? | 変更を破棄しますか？ | 변경 사항을 취소할까요? |
| keepEditing | 继续编辑 | 繼續編輯 | Keep editing | 編集を続ける | 계속 편집 |
| checked | 我已在电脑确认结果 | 我已在電腦確認結果 | I checked the result on the computer | パソコンで結果を確認しました | 컴퓨터에서 결과를 확인했습니다 |
| status.offline | 电脑离线 | 電腦離線 | Computer offline | パソコンがオフラインです | 컴퓨터 오프라인 |
| status.unavailable | 资源已不可用或访问被撤销 | 資源已無法使用或存取已撤銷 | Resource unavailable or access revoked | 利用できないかアクセスが取り消されました | 리소스를 사용할 수 없거나 접근 권한이 취소되었습니다 |
| status.failed | 读取失败，请重试 | 讀取失敗，請重試 | Could not load. Try again. | 読み込めませんでした。再試行してください | 불러오지 못했습니다. 다시 시도하세요 |
| status.unknown | 结果未确认，请先在电脑检查，避免重复创建 | 結果尚未確認，請先在電腦檢查，避免重複建立 | Result unknown. Check the computer before creating again. | 結果を確認できません。再作成の前にパソコンで確認してください | 결과가 확인되지 않았습니다. 다시 만들기 전에 컴퓨터에서 확인하세요 |
| status.invalid | 请检查填写内容 | 請檢查填寫內容 | Check your input | 入力内容を確認してください | 입력 내용을 확인하세요 |
| status.confirmation | 请先确认此操作 | 請先確認此操作 | Confirm this action first | 操作を確認してください | 먼저 작업을 확인하세요 |

追加文案：

| key | zh-CN | zh-TW | en | ja | ko |
|---|---|---|---|---|---|
| automatic | 自动项目图标 | 自動專案圖示 | Automatic project icon | 自動プロジェクトアイコン | 자동 프로젝트 아이콘 |
| checkingIcon | 正在查找项目图标 | 正在尋找專案圖示 | Looking for project icon | アイコンを検索中 | 프로젝트 아이콘 찾는 중 |
| noIcon | 未找到项目图标 | 找不到專案圖示 | No project icon found | アイコンが見つかりません | 프로젝트 아이콘을 찾지 못했습니다 |

## 图标 RPC 准入（电脑同账号，沿 invokeOwnedModule）

| RPC | 参数 | 响应 / 能力 |
|---|---|---|
| `sidebar-settings:get-project-icon-image` | `[{projectKey}]` | 已登记图片 data URI；`settingsVersion >= 2` |
| `sidebar-settings:get-project-auto-icon` | `[{projectKey}]` | `{image: dataURI|null,source,kind:local|website|github|none,candidate:boolean}`；`settingsVersion >= 4` |

均按完整主机项目身份查询，不能传媒体地址或任意文件路径；返回后按scope代次检查。文案接线改用
`components/projects/ProjectStrings.createProjectLabels(locale)` 和
`components/resources/ResourceStrings.createResourceLabels(locale)`，覆盖简中、繁中、英、日、韩；
所有issue码经`resourceIssueText`转译，未知码回退通用失败而不显示原始代码。
