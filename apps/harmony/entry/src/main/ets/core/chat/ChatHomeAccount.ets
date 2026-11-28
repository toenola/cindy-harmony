import { AuthStore } from '../auth/AuthStore';
export interface ChatHomeAccountIdentity { account(): string; epoch(): number; signedIn(): boolean }
export class ChatHomeAuthIdentity implements ChatHomeAccountIdentity {
  private auth: AuthStore;
  constructor(auth:AuthStore){this.auth=auth;}
  account():string{return this.auth.cacheAccountId;}
  epoch():number{return this.auth.sessionEpoch;}
  signedIn():boolean{return this.auth.isLoggedIn;}
}
/** Root view fields may be rebound before ArkUI unmounts an old child. Capture identity,
 * not merely a predicate comparing two mutable current-store references. */
export function captureChatHomeAccount(identity:ChatHomeAccountIdentity,current:()=>boolean):()=>boolean{
  const account=identity.account(),epoch=identity.epoch();
  return():boolean=>!!account&&identity.signedIn()&&identity.account()===account&&identity.epoch()===epoch&&current();
}
