/**
 * 会话消息范围选择（纯逻辑）。
 *
 * 选择模式与普通消息点击、长按选文和滚动相互独立：页面只把稳定的消息
 * clientId（旧历史回退到 id / render key）交给本 Store，不保存消息对象引用。
 * 这样流式刷新或历史分页替换渲染节点时，勾选状态不会跟着对象身份漂移。
 */

export type ShareSelectionListener = () => void;

export class ShareSelectionStore {
  private session: string = '';
  private selected: Set<string> = new Set<string>();
  private listeners: ShareSelectionListener[] = [];
  private changeRevision: number = 0;

  activeSessionId(): string {
    return this.session;
  }

  revision(): number {
    return this.changeRevision;
  }

  isActive(): boolean {
    return this.session.length > 0;
  }

  isSelected(id: string): boolean {
    return id.length > 0 && this.selected.has(id);
  }

  count(): number {
    return this.selected.size;
  }

  selectedIds(): string[] {
    const out: string[] = [];
    this.selected.forEach((id: string): void => {
      out.push(id);
    });
    return out;
  }

  /** 进入选择模式；重复进入同一任务不会清空用户已勾选内容。 */
  enter(sessionId: string, preselectedId: string = ''): void {
    if (sessionId.length === 0) {
      this.exit();
      return;
    }
    let changed = false;
    if (this.session !== sessionId) {
      this.session = sessionId;
      this.selected.clear();
      changed = true;
    }
    if (preselectedId.length > 0 && !this.selected.has(preselectedId)) {
      this.selected.add(preselectedId);
      changed = true;
    }
    if (changed) this.notifyChanged();
  }

  exit(): void {
    if (this.session.length === 0 && this.selected.size === 0) return;
    this.session = '';
    this.selected.clear();
    this.notifyChanged();
  }

  toggle(id: string): void {
    if (!this.isActive() || id.length === 0) return;
    if (this.selected.has(id)) this.selected.delete(id);
    else this.selected.add(id);
    this.notifyChanged();
  }

  setSelection(ids: string[]): void {
    const next = new Set<string>();
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      if (id.length > 0) next.add(id);
    }
    if (this.sameSelection(next)) return;
    this.selected = next;
    this.notifyChanged();
  }

  /** 消息刷新或分页后，只保留仍在当前可见投影中的消息。 */
  reconcile(visibleIds: string[]): void {
    if (!this.isActive()) return;
    const visible = new Set<string>();
    for (let i = 0; i < visibleIds.length; i++) {
      if (visibleIds[i].length > 0) visible.add(visibleIds[i]);
    }
    const next: string[] = [];
    this.selected.forEach((id: string): void => {
      if (visible.has(id)) next.push(id);
    });
    this.setSelection(next);
  }

  /** 按消息渲染顺序返回已选 ID，避免 Set 插入顺序被分页/全选操作影响。 */
  selectedIdsInOrder(renderOrder: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < renderOrder.length; i++) {
      const id = renderOrder[i];
      if (id.length > 0 && this.selected.has(id) && out.indexOf(id) < 0) out.push(id);
    }
    return out;
  }

  onChanged(listener: ShareSelectionListener): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  private sameSelection(next: Set<string>): boolean {
    if (next.size !== this.selected.size) return false;
    let same = true;
    this.selected.forEach((id: string): void => {
      if (!next.has(id)) same = false;
    });
    return same;
  }

  private notifyChanged(): void {
    this.changeRevision += 1;
    const snapshot = this.listeners.slice();
    for (let i = 0; i < snapshot.length; i++) snapshot[i]();
  }
}
