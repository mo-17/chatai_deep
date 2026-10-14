import { Module } from '@nestjs/common';
import { CloudWorkflowStore } from './cloud-workflow.store';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import { CloudWorkflowService } from './cloud-workflow.service';
import { CloudWorkflowGuard } from './cloud-workflow.guard';
import { CloudWorkflowController } from './cloud-workflow.controller';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import { CloudWorkflowTransport } from './cloud-workflow.transport';
import { CloudWorkflowWorker } from './cloud-workflow.worker';
import { CloudWorkflowPrivateRuntime } from './cloud-workflow.private-runtime';

@Module({
  controllers: [CloudWorkflowController],
  providers: [
    CloudWorkflowStore,
    CloudWorkflowReadiness,
    CloudWorkflowService,
    CloudWorkflowGuard,
    CloudWorkflowExecutionStore,
    CloudWorkflowTransport,
    CloudWorkflowWorker,
    CloudWorkflowPrivateRuntime,
  ],
  exports: [CloudWorkflowWorker],
})
export class CloudWorkflowModule {}
