import { HdsNavigation, HdsNavigationTitleMode, NavDestinationBuilder } from '@kit.UIDesignKit';
import { SubHeader } from '@kit.ArkUI';

/** Only for the owner of a navigation shell. Do not nest a second navigation tree just for its header. */
@Component
export struct UiNavigation {
  @Require @Prop heading: ResourceStr = '';
  @Prop subtitle?: ResourceStr;
  @Prop showBack: boolean = false;
  navPath: NavPathStack = new NavPathStack();
  @BuilderParam content: () => void = this.emptyContent;
  @BuilderParam destination: NavDestinationBuilder = this.emptyDestination;

  @Builder
  private emptyContent() {}

  @Builder
  private emptyDestination(_name: string, _params: Object) {}

  build() {
    HdsNavigation(this.navPath) {
      this.content()
    }
    .navDestination(this.destination)
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar({ content: { title: { mainTitle: this.heading, subTitle: this.subtitle } } })
    .hideBackButton(!this.showBack)
    .hideToolBar(true)
    .width('100%')
    .height('100%')
  }
}

/** Header for inline or builder-based surfaces that do not own navigation. */
@Component
export struct UiPanelHeading {
  @Require @Prop heading: ResourceStr = '';

  build() {
    SubHeader({ primaryTitle: this.heading })
      .width('100%')
  }
}
