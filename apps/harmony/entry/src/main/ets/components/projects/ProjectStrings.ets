import { ProjectLabels } from './ProjectSettingsPanel';
import { resourceLanguageIndex, resourceIssueText } from '../../core/resources/ResourceIssueStrings';

export function createProjectLabels(locale: string): ProjectLabels {
  const labels = new ProjectLabels();
  const index = resourceLanguageIndex(locale);
  labels.name = ["名称", "名稱", "Name", "名前", "이름"][index];
  labels.directory = ["项目目录", "專案目錄", "Project directories", "プロジェクトフォルダ", "프로젝트 폴더"][index];
  labels.repository = ["仓库链接", "儲存庫連結", "Repository URL", "リポジトリURL", "저장소 URL"][index];
  labels.local = ["电脑文件夹", "電腦資料夾", "Computer folder", "パソコンのフォルダ", "컴퓨터 폴더"][index];
  labels.computer = ["电脑", "電腦", "Computer", "パソコン", "컴퓨터"][index];
  labels.save = ["保存", "儲存", "Save", "保存", "저장"][index];
  labels.create = ["创建项目", "建立專案", "Create project", "プロジェクトを作成", "프로젝트 만들기"][index];
  labels.cancel = ["取消", "取消", "Cancel", "キャンセル", "취소"][index];
  labels.refresh = ["刷新", "重新整理", "Refresh", "更新", "새로고침"][index];
  labels.addDirectory = ["添加目录", "新增目錄", "Add directory", "フォルダを追加", "폴더 추가"][index];
  labels.remove = ["移除", "移除", "Remove", "削除", "제거"][index];
  labels.main = ["主目录", "主目錄", "Main directory", "メインフォルダ", "기본 폴더"][index];
  labels.icon = ["图标", "圖示", "Icon", "アイコン", "아이콘"][index];
  labels.reset = ["恢复默认", "恢復預設", "Reset", "初期設定に戻す", "기본값으로 복원"][index];
  labels.upload = ["上传图片", "上傳圖片", "Upload image", "画像をアップロード", "이미지 업로드"][index];
  labels.letters = ["1–2 个文字", "1–2 個文字", "1–2 letters", "1〜2文字", "1~2자"][index];
  labels.discard = ["放弃修改？", "放棄修改？", "Discard changes?", "変更を破棄しますか？", "변경 사항을 취소할까요?"][index];
  labels.keepEditing = ["继续编辑", "繼續編輯", "Keep editing", "編集を続ける", "계속 편집"][index];
  labels.automatic = ["自动项目图标", "自動專案圖示", "Automatic project icon", "自動プロジェクトアイコン", "자동 프로젝트 아이콘"][index];
  labels.checkingIcon = ["正在查找项目图标", "正在尋找專案圖示", "Looking for project icon", "アイコンを検索中", "프로젝트 아이콘 찾는 중"][index];
  labels.noIcon = ["未找到项目图标", "找不到專案圖示", "No project icon found", "アイコンが見つかりません", "프로젝트 아이콘을 찾지 못했습니다"][index];
  labels.checked = ["我已在电脑确认结果", "我已在電腦確認結果", "I checked the result on the computer", "パソコンで結果を確認しました", "컴퓨터에서 결과를 확인했습니다"][index];
  labels.status = (issue: string): string => resourceIssueText(issue, locale);
  return labels;
}
