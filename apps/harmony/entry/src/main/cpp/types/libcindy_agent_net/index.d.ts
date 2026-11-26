export const create: (options: string) => object;
export const command: (engine: object, input: string) => string;
export const destroy: (engine: object) => void;

export interface AgentNetNative {
  create(options: string): object;
  command(engine: object, input: string): string;
  destroy(engine: object): void;
}
declare const agentNet: AgentNetNative;
export default agentNet;
