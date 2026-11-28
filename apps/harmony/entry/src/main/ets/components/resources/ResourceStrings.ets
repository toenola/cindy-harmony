import { ResourcesLabels } from './ResourcesPanel';
import { resourceLanguageIndex, resourceIssueText } from '../../core/resources/ResourceIssueStrings';

export function createResourceLabels(locale: string): ResourcesLabels {
  const labels = new ResourcesLabels();
  const index = resourceLanguageIndex(locale);
  labels.refresh = ["刷新", "重新整理", "Refresh", "更新", "새로고침"][index];
  labels.more = ["加载更多", "載入更多", "Load more", "さらに読み込む", "더 불러오기"][index];
  labels.back = ["返回", "返回", "Back", "戻る", "뒤로"][index];
  labels.search = ["搜索", "搜尋", "Search", "検索", "검색"][index];
  labels.empty = ["暂无内容", "尚無內容", "Nothing here yet", "まだありません", "아직 내용이 없습니다"][index];
  labels.openTask = ["打开任务", "開啟任務", "Open task", "タスクを開く", "작업 열기"][index];
  labels.unread = ["未读", "未讀", "Unread", "未読", "읽지 않음"][index];
  labels.unsupported = ["暂不支持", "尚不支援", "Not supported", "未対応", "지원되지 않음"][index];
  labels.cancel = ["取消", "取消", "Cancel", "キャンセル", "취소"][index];
  labels.confirm = ["确认", "確認", "Confirm", "確認", "확인"][index];
  labels.status = (issue: string): string => resourceIssueText(issue, locale);
  return labels;
}
