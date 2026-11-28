/** All unknown failures use a translated recovery message, never a raw protocol code. */
export function resourceLanguageIndex(locale: string): number {
  const value = locale.toLowerCase();
  if (value.startsWith('zh')) return value.includes('tw') || value.includes('hk') || value.includes('hant') ? 1 : 0;
  if (value.startsWith('ja')) return 3;
  if (value.startsWith('ko')) return 4;
  return 2;
}
export function resourceIssueText(issue: string, locale: string): string {
  if (!issue) return '';
  const index = resourceLanguageIndex(locale);
  switch (issue) {
    case "offline": return ["电脑离线", "電腦離線", "Computer offline", "パソコンがオフラインです", "컴퓨터 오프라인"][index];
    case "unavailable": return ["资源已不可用或访问被撤销", "資源已無法使用或存取已撤銷", "Resource unavailable or access revoked", "利用できないかアクセスが取り消されました", "리소스를 사용할 수 없거나 접근 권한이 취소되었습니다"][index];
    case "failed": return ["读取失败，请重试", "讀取失敗，請重試", "Could not load. Try again.", "読み込めませんでした。再試行してください", "불러오지 못했습니다. 다시 시도하세요"][index];
    case "unknown": return ["结果未确认，请先在电脑检查，避免重复创建", "結果尚未確認，請先在電腦檢查，避免重複建立", "Result unknown. Check the computer before creating again.", "結果を確認できません。再作成の前にパソコンで確認してください", "결과가 확인되지 않았습니다. 다시 만들기 전에 컴퓨터에서 확인하세요"][index];
    case "invalid": return ["请检查填写内容", "請檢查填寫內容", "Check your input", "入力内容を確認してください", "입력 내용을 확인하세요"][index];
    case "confirmation": return ["请先确认此操作", "請先確認此操作", "Confirm this action first", "操作を確認してください", "먼저 작업을 확인하세요"][index];
    case "unsupported": return ["暂不支持", "尚不支援", "Not supported", "未対応", "지원되지 않음"][index];
    default: return ["读取失败，请重试", "讀取失敗，請重試", "Could not load. Try again.", "読み込めませんでした。再試行してください", "불러오지 못했습니다. 다시 시도하세요"][index];
  }
}
