import { resourceLanguageIndex } from '../../core/resources/ResourceIssueStrings';
export class SharedTaskLabels {
  title: string = 'Shared tasks'; owned: string = 'Started by me'; joined: string = 'Joined by me';
  join: string = 'Join shared task'; invitation: string = 'Invitation link or code'; open: string = 'Open task';
  manage: string = 'Manage'; share: string = 'Share this task'; invite: string = 'New invitation'; copy: string = 'Copy invitation';
  leave: string = 'Leave'; stop: string = 'Stop sharing'; remove: string = 'Remove'; back: string = 'Back';
  refresh: string = 'Refresh'; empty: string = 'No shared tasks'; members: string = 'Members';
  cancel: string = 'Cancel'; confirm: string = 'Confirm'; confirmBody: string = 'This changes access to the shared task.';
  issue: (value: string) => string = (value: string): string => sharedTaskIssue(value, 'en');
}
export function sharedTaskIssue(issue: string, locale: string): string {
  const index = resourceLanguageIndex(locale);
  switch (issue) {
    case '': return '';
    case 'ended': return ['共享已结束或你已退出。重新加入需要房主的新邀请。','共享已結束或你已退出。重新加入需要房主的新邀請。','Sharing ended or you left. Ask the host for a new invitation.','共有が終了したか退出しました。新しい招待が必要です。','공유가 종료되었거나 나갔습니다. 호스트에게 새 초대를 요청하세요.'][index];
    case 'unsupported': return ['当前连接尚不支持共享任务，请更新电脑端或检查共享连接。','目前連線尚不支援共享任務，請更新電腦端或檢查共享連線。','This connection does not support shared tasks. Update the computer or check the sharing connection.','この接続は共有タスクに未対応です。パソコンまたは共有接続を確認してください。','현재 연결은 공유 작업을 지원하지 않습니다. 컴퓨터 업데이트 또는 공유 연결을 확인하세요.'][index];
    case 'self': return ['不能加入自己发起的共享，请直接打开原任务。','無法加入自己發起的共享，請直接開啟原任務。','Open your original task instead of joining your own invitation.','自分の招待には参加できません。元のタスクを開いてください。','자신의 초대로 참여할 수 없습니다. 원래 작업을 여세요.'][index];
    case 'full': return ['已达到共享名额，请先管理已有共享。','已達到共享名額，請先管理現有共享。','The sharing limit has been reached. Manage existing shared tasks first.','共有の上限に達しました。既存の共有を確認してください。','공유 한도에 도달했습니다. 기존 공유 작업을 관리하세요.'][index];
    case 'different-server': case 'invitation': case 'invalid': return ['邀请无效、过期或不属于当前共享服务，请检查后重试。','邀請無效、過期或不屬於目前共享服務，請檢查後重試。','The invitation is invalid, expired, or belongs to another sharing service.','招待が無効、期限切れ、または別の共有サービス用です。','초대가 유효하지 않거나 만료되었거나 다른 공유 서비스의 초대입니다.'][index];
    case 'forbidden': return ['你没有执行此操作的权限。','你沒有執行此操作的權限。','You do not have permission for this action.','この操作の権限がありません。','이 작업을 수행할 권한이 없습니다.'][index];
    default: return ['共享状态更新失败，请检查连接后重试。','共享狀態更新失敗，請檢查連線後重試。','Could not update sharing. Check the connection and try again.','共有状態を更新できませんでした。接続を確認して再試行してください。','공유 상태를 업데이트하지 못했습니다. 연결을 확인하고 다시 시도하세요.'][index];
  }
}
export function createSharedTaskLabels(locale: string): SharedTaskLabels {
  const index = resourceLanguageIndex(locale), labels = new SharedTaskLabels();
  labels.title = ['共享任务','共享任務','Shared tasks','共有タスク','공유 작업'][index];
  labels.owned = ['我发起的','我發起的','Started by me','自分が開始','내가 시작한 작업'][index];
  labels.joined = ['我加入的','我加入的','Joined by me','参加中','참여한 작업'][index];
  labels.join = ['加入共享任务','加入共享任務','Join shared task','共有タスクに参加','공유 작업 참여'][index];
  labels.invitation = ['邀请链接或邀请码','邀請連結或邀請碼','Invitation link or code','招待リンクまたはコード','초대 링크 또는 코드'][index];
  labels.open = ['打开任务','開啟任務','Open task','タスクを開く','작업 열기'][index];
  labels.manage = ['管理','管理','Manage','管理','관리'][index];
  labels.share = ['共享此任务','共享此任務','Share this task','このタスクを共有','이 작업 공유'][index];
  labels.invite = ['生成新邀请','產生新邀請','New invitation','新しい招待','새 초대'][index];
  labels.copy = ['复制邀请','複製邀請','Copy invitation','招待をコピー','초대 복사'][index];
  labels.leave = ['退出共享','退出共享','Leave','退出','나가기'][index];
  labels.stop = ['停止共享','停止共享','Stop sharing','共有を停止','공유 중지'][index];
  labels.remove = ['移除','移除','Remove','削除','제거'][index];
  labels.back = ['返回','返回','Back','戻る','뒤로'][index];
  labels.refresh = ['刷新','重新整理','Refresh','更新','새로고침'][index];
  labels.empty = ['暂无共享任务','尚無共享任務','No shared tasks','共有タスクはありません','공유 작업이 없습니다'][index];
  labels.members = ['成员','成員','Members','メンバー','멤버'][index];
  labels.cancel = ['取消','取消','Cancel','キャンセル','취소'][index];
  labels.confirm = ['确认','確認','Confirm','確認','확인'][index];
  labels.confirmBody = ['此操作会改变共享任务的访问权限。','此操作會變更共享任務的存取權限。','This changes access to the shared task.','共有タスクへのアクセス権が変わります。','공유 작업에 대한 접근 권한이 변경됩니다.'][index];
  labels.issue = (value: string): string => sharedTaskIssue(value, locale); return labels;
}
