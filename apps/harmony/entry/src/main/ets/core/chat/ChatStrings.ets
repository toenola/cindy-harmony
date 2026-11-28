/** Module-owned vocabulary; no mutation of shared locale JSON during parallel work. */
export class ChatStrings {
  search: string = ''; groups: string = ''; cloud: string = ''; send: string = ''; retry: string = '';
  older: string = ''; removed: string = ''; topic: string = ''; main: string = ''; settings: string = '';
  back: string = ''; refresh: string = ''; empty: string = ''; message: string = ''; unknown: string = '';
}
export function chatStrings(locale: string): ChatStrings {
  let words: string[];
  if (locale.startsWith('zh-TW') || locale.startsWith('zh-Hant')) words = ['搜尋夥伴和群聊', '溝通', '雲端', '傳送', '重試', '載入更早', '訊息已刪除', '話題', '主群', '群設定', '返回', '重新整理', '尚無群聊', '訊息', '送達狀態未知'];
  else if (locale.startsWith('zh')) words = ['搜索伙伴和群聊', '沟通', '云端', '发送', '重试', '加载更早', '消息已删除', '话题', '主群', '群设置', '返回', '刷新', '暂无群聊', '消息', '送达状态未知'];
  else if (locale.startsWith('ja')) words = ['仲間とグループを検索', 'チャット', 'クラウド', '送信', '再試行', '以前を読み込む', '削除されたメッセージ', 'スレッド', 'メイン', 'グループ設定', '戻る', '更新', 'グループはありません', 'メッセージ', '配信状態不明'];
  else if (locale.startsWith('ko')) words = ['동료 및 그룹 검색', '대화', '클라우드', '보내기', '재시도', '이전 메시지', '삭제된 메시지', '스레드', '메인', '그룹 설정', '뒤로', '새로고침', '그룹 없음', '메시지', '전송 상태 알 수 없음'];
  else words = ['Search companions and groups', 'Chat', 'Cloud', 'Send', 'Retry', 'Load earlier', 'Message deleted', 'Topic', 'Main group', 'Group settings', 'Back', 'Refresh', 'No groups yet', 'Message', 'Delivery unknown'];
  const s = new ChatStrings(); s.search = words[0]; s.groups = words[1]; s.cloud = words[2]; s.send = words[3];
  s.retry = words[4]; s.older = words[5]; s.removed = words[6]; s.topic = words[7]; s.main = words[8];
  s.settings = words[9]; s.back = words[10]; s.refresh = words[11]; s.empty = words[12]; s.message = words[13]; s.unknown = words[14]; return s;
}
export class ChatActionStrings {
  quote: string = ''; cancel: string = ''; photos: string = ''; files: string = ''; topics: string = ''; mentions: string = '';
  mentionAll: string = ''; react: string = ''; save: string = ''; name: string = ''; archive: string = ''; restore: string = '';
  nickname: string = ''; invite: string = ''; join: string = ''; preview: string = ''; leave: string = ''; members: string = '';
  admin: string = ''; member: string = ''; owner: string = ''; notifications: string = ''; all: string = ''; none: string = '';
  remove: string = ''; transfer: string = ''; dissolve: string = ''; confirm: string = ''; offline: string = ''; copy: string = '';
}
export function chatActionStrings(locale: string): ChatActionStrings {
  let w: string[];
  if (locale.startsWith('zh-TW') || locale.startsWith('zh-Hant')) w = ['引用回覆','取消','圖片','檔案','話題','提到我','@所有人','回應','儲存','群名稱','封存','恢復','群暱稱','邀請朋友','加入群聊','預覽邀請','退出群聊','成員','管理員','成員','群主','通知','全部','關閉','移除成員','轉讓群主','解散群聊','確認','離線記錄','複製'];
  else if (locale.startsWith('zh')) w = ['引用回复','取消','图片','文件','话题','提到我','@所有人','回应','保存','群名称','归档','恢复','群昵称','邀请朋友','加入群聊','预览邀请','退出群聊','成员','管理员','成员','群主','通知','全部','关闭','移除成员','转让群主','解散群聊','确认','离线记录','复制'];
  else if (locale.startsWith('ja')) w = ['引用して返信','キャンセル','画像','ファイル','スレッド','自分へのメンション','@全員','リアクション','保存','グループ名','アーカイブ','復元','ニックネーム','友達を招待','参加','招待を確認','退出','メンバー','管理者','メンバー','オーナー','通知','すべて','なし','メンバーを削除','オーナーを譲渡','グループを解散','確認','オフライン履歴','コピー'];
  else if (locale.startsWith('ko')) w = ['인용 답장','취소','이미지','파일','스레드','내 멘션','@모두','반응','저장','그룹 이름','보관','복원','닉네임','친구 초대','참여','초대 미리보기','나가기','멤버','관리자','멤버','소유자','알림','전체','없음','멤버 제거','소유권 이전','그룹 해산','확인','오프라인 기록','복사'];
  else w = ['Quote reply','Cancel','Photos','Files','Topics','Mentions','@Everyone','React','Save','Group name','Archive','Restore','Group nickname','Invite friends','Join group','Preview invitation','Leave group','Members','Admin','Member','Owner','Notifications','All','None','Remove member','Transfer ownership','Dissolve group','Confirm','Offline history','Copy'];
  const s = new ChatActionStrings(); s.quote=w[0];s.cancel=w[1];s.photos=w[2];s.files=w[3];s.topics=w[4];s.mentions=w[5];
  s.mentionAll=w[6];s.react=w[7];s.save=w[8];s.name=w[9];s.archive=w[10];s.restore=w[11];s.nickname=w[12];s.invite=w[13];
  s.join=w[14];s.preview=w[15];s.leave=w[16];s.members=w[17];s.admin=w[18];s.member=w[19];s.owner=w[20];s.notifications=w[21];
  s.all=w[22];s.none=w[23];s.remove=w[24];s.transfer=w[25];s.dissolve=w[26];s.confirm=w[27];s.offline=w[28];s.copy=w[29];return s;
}
/** Stable product wording; diagnostics and signed URLs never become visible error prose. */
export function chatErrorText(locale: string, code: string): string {
  let w: string[];
  if (locale.startsWith('zh-TW') || locale.startsWith('zh-Hant')) w = ['暫時無法連線，請重試','請重新登入','你目前沒有此操作權限','目前版本不支援此操作','雲端記錄唯讀，請返回夥伴主對話繼續','記錄暫存已滿，請稍後重試','邀請已失效或已過期','傳送中','等待傳送','傳送失敗，請重試'];
  else if (locale.startsWith('zh')) w = ['暂时无法连接，请重试','请重新登录','你目前没有此操作权限','当前版本不支持此操作','云端记录只读，请返回伙伴主对话继续','记录缓存已满，请稍后重试','邀请已失效或已过期','发送中','等待发送','发送失败，请重试'];
  else if (locale.startsWith('ja')) w = ['接続できません。再試行してください','再ログインしてください','この操作の権限がありません','このバージョンでは利用できません','クラウド履歴は読み取り専用です。仲間のメインチャットに戻ってください','履歴キャッシュがいっぱいです','招待が無効か期限切れです','送信中','送信待ち','送信に失敗しました'];
  else if (locale.startsWith('ko')) w = ['연결할 수 없습니다. 다시 시도하세요','다시 로그인하세요','이 작업의 권한이 없습니다','현재 버전에서 지원하지 않습니다','클라우드 기록은 읽기 전용입니다. 동료의 기본 대화로 돌아가세요','기록 캐시가 가득 찼습니다','초대가 만료되었거나 유효하지 않습니다','보내는 중','전송 대기','전송에 실패했습니다'];
  else w = ['Unable to connect. Try again.','Sign in again.','You do not have permission for this action.','This version does not support this action.','Cloud history is read-only. Return to the companion’s main chat to continue.','History cache is full. Try again later.','The invitation is invalid or expired.','Sending','Waiting to send','Delivery failed. Try again.'];
  if (/AUTH|TOKEN|OWNER_CHANGED|HTTP_401/.test(code)) return w[1];
  if (/ROLE|PERMISSION|HTTP_403|GROUP_CLOSED/.test(code)) return w[2];
  if (/UNSUPPORTED/.test(code)) return w[3];
  if (code === 'COMPANION_READ_ONLY') return w[4];
  if (/CACHE_FULL|OUTBOX_FULL/.test(code)) return w[5];
  if (/INVITATION|INVALID_CHAT_RESPONSE/.test(code)) return w[6];
  if (code === 'sending') return w[7]; if (code === 'queued') return w[8]; if (code === 'failed') return w[9]; return w[0];
}
export function chatDestructiveText(locale: string, type: string, name: string): string {
  let w: string[];
  if (locale.startsWith('zh-TW') || locale.startsWith('zh-Hant')) w = ['解散後無法恢復，所有成員將停止發言和執行，邀請也會失效。','退出後將帶走你的夥伴，並失去本群存取權。','移除後該成員將失去本群存取權。','轉讓後你將不再是群主。'];
  else if (locale.startsWith('zh')) w = ['解散后无法恢复，所有成员将停止发言和执行，邀请也会失效。','退出后将带走你的伙伴，并失去本群访问权。','移除后该成员将失去本群访问权。','转让后你将不再是群主。'];
  else if (locale.startsWith('ja')) w = ['解散は取り消せません。全員の発言・実行が停止し、招待は無効になります。','退出すると自分の仲間も退出し、このグループへのアクセスを失います。','削除されたメンバーはアクセスできなくなります。','譲渡後はグループのオーナーではなくなります。'];
  else if (locale.startsWith('ko')) w = ['해산은 되돌릴 수 없습니다. 모든 멤버의 발언과 실행이 중지되고 초대가 무효화됩니다.','나가면 내 동료도 함께 나가며 그룹 접근 권한을 잃습니다.','제거된 멤버는 접근 권한을 잃습니다.','이전 후에는 그룹 소유자가 아니게 됩니다.'];
  else w = ['Dissolving cannot be undone. All members’ messages and executions stop, and invitations become invalid.','Leaving also removes your companions and ends your access to this group.','The removed member will lose access to this group.','You will no longer own this group after transferring it.'];
  return `${name}\n${w[type === 'dissolve' ? 0 : type === 'leave' ? 1 : type === 'transfer' ? 3 : 2]}`;
}

export function chatRevokeInviteText(locale:string):string {
  if(locale.startsWith('zh-TW')||locale.startsWith('zh-Hant'))return '撤銷邀請：此連結將無法再用於加入群聊';
  if(locale.startsWith('zh'))return '撤销邀请：此链接将无法再用于加入群聊';
  if(locale.startsWith('ja'))return '招待を取り消す：このリンクから参加できなくなります';
  if(locale.startsWith('ko'))return '초대 취소: 이 링크로 더 이상 참여할 수 없습니다';
  return 'Revoke invitation: this link will no longer allow people to join';
}
