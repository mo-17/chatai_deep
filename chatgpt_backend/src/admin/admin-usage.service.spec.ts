import { AdminUsageService, sanitizeCsvCell } from './admin-usage.service';

describe('AdminUsageService CSV export', () => {
  it.each([
    ['=1+1', `"'=1+1"`],
    [' +CMD', `"' +CMD"`],
    ['\t-HYPERLINK("https://evil")', `"'\t-HYPERLINK(""https://evil"")"`],
    ['\uFEFF=1+1', `"'\uFEFF=1+1"`],
    ['\u00A0@SUM(1,1)', `"'\u00A0@SUM(1,1)"`],
    ['@SUM(1,1)', `"'@SUM(1,1)"`],
    ['normal,"quoted"\nline', `"normal,""quoted""\nline"`],
  ])('统一 sanitizer 安全编码 CSV cell：%j', (input, expected) => {
    expect(sanitizeCsvCell(input)).toBe(expected);
  });

  it('从持久化 usage 与用户名导出时中和所有公式型文本字段', async () => {
    const createdAt = new Date('2026-08-24T01:02:03.000Z');
    const repo = {
      find: jest.fn().mockResolvedValue([
        {
          id: 1,
          userId: 7,
          provider: ' +cmd|calc',
          model: '@SUM(1,1)',
          promptTokens: 2,
          completionTokens: 3,
          totalTokens: 5,
          createdAt,
        },
      ]),
      manager: {
        find: jest
          .fn()
          .mockResolvedValue([
            { id: 7, userName: '=HYPERLINK("https://evil")' },
          ]),
      },
    };
    const service = new AdminUsageService(repo as never);

    const csv = await service.exportCsv({});

    expect(csv).toContain(`"'=HYPERLINK(""https://evil"")"`);
    expect(csv).toContain(`"' +cmd|calc"`);
    expect(csv).toContain(`"'@SUM(1,1)"`);
    expect(csv).toContain(`"2026-08-24T01:02:03.000Z"`);
  });

  it('合法内容保持原值并正确处理逗号与引号', async () => {
    const repo = {
      find: jest.fn().mockResolvedValue([
        {
          id: 2,
          userId: 8,
          provider: 'openai',
          model: 'gpt-5',
          promptTokens: 10,
          completionTokens: 20,
          totalTokens: 30,
          createdAt: new Date('2026-08-24T02:00:00.000Z'),
        },
      ]),
      manager: {
        find: jest
          .fn()
          .mockResolvedValue([{ id: 8, userName: '张三, "测试"' }]),
      },
    };
    const service = new AdminUsageService(repo as never);

    const csv = await service.exportCsv({});

    expect(csv.startsWith('\uFEFF')).toBe(true);
    expect(csv).toContain(`"张三, ""测试"""`);
    expect(csv).toContain(`"openai","gpt-5","10","20","30"`);
    expect(csv).not.toContain(`"'openai"`);
  });
});
