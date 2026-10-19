import { DataSource } from 'typeorm';
import { AccessService } from '../access/access.service';
import { OperationsService } from './operations.service';

describe('operations snapshot', () => {
  it('reports persistent budget and process-scoped metrics, warning at 80 percent', async () => {
    const db = {
      query: jest
        .fn()
        .mockResolvedValue([{ tokens: 80000, requests: 400, active: 1 }]),
    };
    const access = {
      policy: jest.fn().mockResolvedValue({
        globalDailyTokens: 100000,
        globalDailyRequests: 500,
        globalMaxConcurrent: 4,
        limitsEnabled: true,
        trialEnabled: true,
      }),
    };
    const service = new OperationsService(
      db as unknown as DataSource,
      access as unknown as AccessService,
    );
    for (let i = 0; i < 3; i++) service.metrics.record('chat', 502, 10);
    const value = await service.snapshot();
    expect(value.database.ok).toBe(true);
    expect(value.budget.tokens).toBe(80000);
    expect(value.alerts.map((alert) => alert.code)).toEqual([
      'TOKEN_BUDGET',
      'REQUEST_BUDGET',
      'HTTP_ERRORS',
    ]);
    expect(value.memory.rssBytes).toBeGreaterThan(0);
    db.query.mockRejectedValueOnce(new Error('synthetic db failure'));
    await expect(service.snapshot()).rejects.toThrow();
  });
});
