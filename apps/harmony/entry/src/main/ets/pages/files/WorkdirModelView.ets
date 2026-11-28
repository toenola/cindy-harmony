import { UiInlineError } from '../../components/common/UiStatus';
import { UI_FONT_SECONDARY } from '../../components/UiKit';
import { Camera, Scene } from '@ohos.graphics.scene';
import { WorkdirModelLease } from '../../core/files/WorkdirModel';

@Component
export struct WorkdirModelView {
  lease: WorkdirModelLease | null = null;
  @State private ready: boolean = false;
  @State private error: string = '';
  private scene: Scene | null = null;
  private camera: Camera | null = null;
  private live: boolean = false;
  private yaw: number = 0;
  private pitch: number = 0;
  private distance: number = 3;
  private startYaw: number = 0;
  private startPitch: number = 0;
  private startDistance: number = 3;

  aboutToAppear(): void {
    this.live = true;
    void this.load();
  }

  aboutToDisappear(): void {
    this.live = false;
    this.scene?.destroy();
    this.scene = null;
    this.camera = null;
  }

  private async load(): Promise<void> {
    const path = this.lease?.entry ?? '';
    try {
      const scene = await Scene.load('file://' + path);
      if (!this.live) { scene.destroy(); return; }
      this.scene = scene;
      const camera = await scene.getResourceFactory().createCamera({ name: 'CindyPreviewCamera' });
      if (!this.live) return;
      this.camera = camera;
      camera.enabled = true;
      this.updateCamera();
      this.ready = true;
    } catch (_error) {
      if (this.live) this.error = '无法加载此 3D 模型，可以导出或分享';
    }
  }

  private updateCamera(): void {
    const camera = this.camera;
    if (!camera) return;
    const y = this.yaw;
    const p = this.pitch;
    camera.position = { x: this.distance * Math.sin(y) * Math.cos(p),
      y: this.distance * Math.sin(p), z: this.distance * Math.cos(y) * Math.cos(p) };
    const cy = Math.cos(y / 2);
    const sy = Math.sin(y / 2);
    const cp = Math.cos(p / 2);
    const sp = Math.sin(-p / 2);
    camera.rotation = { x: cy * sp, y: sy * cp, z: -sy * sp, w: cy * cp };
  }

  build() {
    Stack() {
      if (this.ready && this.scene !== null) {
        Component3D({ scene: this.scene, modelType: ModelType.TEXTURE }).width('100%').height('100%')
          .gesture(GestureGroup(GestureMode.Parallel,
            PanGesture().onActionStart((): void => {
              this.startYaw = this.yaw;
              this.startPitch = this.pitch;
            }).onActionUpdate((event: GestureEvent): void => {
              this.yaw = this.startYaw - event.offsetX / 100;
              this.pitch = Math.max(-1.45, Math.min(1.45, this.startPitch + event.offsetY / 100));
              this.updateCamera();
            }),
            PinchGesture().onActionStart((): void => {
              this.startDistance = this.distance;
            }).onActionUpdate((event: GestureEvent): void => {
              this.distance = Math.max(0.2, Math.min(100, this.startDistance / Math.max(0.05, event.scale)));
              this.updateCamera();
            })
          ))
      } else {
        if (this.error) { UiInlineError({ message: this.error }) }
        else { Text('正在载入 3D 模型…').fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary')) }
      }
    }.width('100%').height('100%')
  }
}
