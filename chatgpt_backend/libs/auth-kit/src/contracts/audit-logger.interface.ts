/** 审计日志接口（可选）—— 宿主项目实现，记录登录/注册/绑定等事件 */
export interface IAuditLogger {
  log(event: {
    action: string;
    userId?: number;
    identifier?: string;
    channel?: string;
    provider?: string;
    ip?: string;
    success: boolean;
    detail?: string;
  }): void;
}
