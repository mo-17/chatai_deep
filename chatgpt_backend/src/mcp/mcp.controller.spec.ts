import { GUARDS_METADATA } from '@nestjs/common/constants';
import { AdminGuard } from '../auth/admin.guard';
import { McpController } from './mcp.controller';

jest.mock('../auth/token-authentication.service', () => ({
  TokenAuthenticationService: class TokenAuthenticationService {},
}));

describe('McpController authority boundary', () => {
  it('在类级 AdminGuard 下覆盖 tools、servers 与 call 的直调 REST 边界', () => {
    const guards =
      (Reflect.getMetadata(GUARDS_METADATA, McpController) as
        | Array<{ name?: string }>
        | undefined) ?? [];

    expect(guards).toEqual([AdminGuard]);
    expect(guards.map((guard) => guard.name)).toEqual(['AdminGuard']);
  });

  it('普通用户令牌被拒绝，管理员令牌可通过同一 guard', async () => {
    const tokenAuthentication = {
      verify: jest
        .fn()
        .mockResolvedValueOnce({ userId: 7, userName: 'user', role: 'user' })
        .mockResolvedValueOnce({ userId: 1, userName: 'admin', role: 'admin' }),
    };
    const guard = new AdminGuard(tokenAuthentication as never);
    const request = { headers: { authorization: 'Bearer test-token' } };
    const context = {
      switchToHttp: () => ({ getRequest: () => request }),
    };

    await expect(guard.canActivate(context as never)).rejects.toThrow(
      '需要管理员权限',
    );
    await expect(guard.canActivate(context as never)).resolves.toBe(true);
  });

  it('管理员通过共享边界后仍可列出 sibling routes 并调用工具', async () => {
    const svc = {
      serverSummaries: jest.fn().mockResolvedValue([{ id: 'server-1' }]),
      listTools: jest.fn().mockResolvedValue([{ name: 'safe_tool' }]),
      callTool: jest.fn().mockResolvedValue('done'),
    };
    const controller = new McpController(svc as never);

    await expect(controller.tools()).resolves.toEqual({
      code: 0,
      data: {
        configured: true,
        servers: [{ id: 'server-1' }],
        tools: [{ name: 'safe_tool' }],
      },
    });
    await expect(controller.servers()).resolves.toEqual({
      code: 0,
      data: { configured: true, servers: [{ id: 'server-1' }] },
    });
    await expect(
      controller.call({ name: 'safe_tool', arguments: { value: 1 } }),
    ).resolves.toEqual({ code: 0, data: { content: 'done' } });
    expect(svc.callTool).toHaveBeenCalledWith('safe_tool', { value: 1 });
  });

  it('未配置 server 时 tools sibling route 不触发后端连接', async () => {
    const svc = {
      serverSummaries: jest.fn().mockResolvedValue([]),
      listTools: jest.fn(),
    };
    const controller = new McpController(svc as never);

    await expect(controller.tools()).resolves.toEqual({
      code: 0,
      data: { configured: false, servers: [], tools: [] },
    });
    expect(svc.listTools).not.toHaveBeenCalled();
  });
});
