import { projectSymbolPaths } from '../../core/projects/ProjectSymbolPaths';
@Component
export struct ProjectSymbol {
  name: string = 'Folder';
  build() {
    Stack() {
      ForEach(projectSymbolPaths(this.name), (path: string) => {
        Path().commands(path).fill(Color.Transparent).stroke($r('app.color.text_primary')).strokeWidth(2)
      }, (path: string): string => path)
    }.width(24).height(24)
  }
}
