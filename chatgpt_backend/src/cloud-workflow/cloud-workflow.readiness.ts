import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { CLOUD_CONSENT_VERSION, CLOUD_LIMITS } from './cloud-workflow.contract';

/** C1a 没有 worker/恢复/唤醒适配。环境开关不能自行获得执行能力。 */
@Injectable()
export class CloudWorkflowReadiness {
  capabilities() {
    return {
      available: false,
      reason:
        process.env.CLOUD_WORKFLOW_ENABLED === 'true'
          ? 'runtime_not_ready'
          : 'disabled',
      consentVersion: CLOUD_CONSENT_VERSION,
      limits: CLOUD_LIMITS,
      destination: 'cloud',
      estimatedCost: null,
      offlineLogoutPolicy: 'pending_user_confirmation',
      logoutNotice: '离线退出的云任务行为尚待确认；当前未启用云执行',
    };
  }
  requireReady(): void {
    if (!this.capabilities().available)
      throw new ServiceUnavailableException('云任务执行与恢复机制尚未就绪');
  }
}
