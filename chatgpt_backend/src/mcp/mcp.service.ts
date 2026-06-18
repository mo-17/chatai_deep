import {
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { HttpMcpClient, McpClient, StdioMcpClient } from './mcp-client';
import { McpServerConfig, parseMcpServers } from './mcp.config';
import { McpServerEntity } from './mcp-server.entity';

/** 聚合后下发给客户端的工具（名称已加 server 前缀）。 */
export interface AggregatedTool {
  /** 暴露给模型的工具名：mcp__<serverId>__<rawName>。 */
  name: string;
  description?: string;
  /** OpenAI function parameters（直接取 MCP inputSchema）。 */
  parameters: Record<string, unknown>;
  serverId: string;
}

const TOOL_PREFIX = 'mcp__';
const TOOLS_TTL_MS = 60_000;
const SERVERS_TTL_MS = 30_000;

// Resources / Prompts 合成工具的保留 rawName（item 7）。与客户端直连命名保持一致，
// 使同一 server 在「直连 / 后端代理」两种模式下工具名稳定。
const SYN_RESOURCES_LIST = 'resources_list';
const SYN_RESOURCES_READ = 'resources_read';
const SYN_PROMPTS_LIST = 'prompts_list';
const SYN_PROMPTS_GET = 'prompts_get';

/**
 * 后端 MCP Host（方案 B）。server 列表存于 DB（item 4），由管理后台维护；
 * 首次启动若表为空则从 MCP_SERVERS 环境变量播种。懒连接、聚合各 server 的工具
 * （名称加前缀避免冲突）+ 资源/提示词合成工具，并把调用路由回对应 server。
 * 既支持远程 http server，也支持本地 stdio server（后者移动端自身无法连接）。
 */
@Injectable()
export class McpService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(McpService.name);
  private readonly clients = new Map<string, McpClient>();
  /** prefixedName → {serverId, rawName}，列工具时重建，供 call 路由。 */
  private readonly toolIndex = new Map<
    string,
    { serverId: string; rawName: string }
  >();
  private toolCache?: { at: number; tools: AggregatedTool[] };
  private serversCache?: { at: number; list: McpServerConfig[] };

  constructor(
    @InjectRepository(McpServerEntity)
    private readonly repo: Repository<McpServerEntity>,
    private readonly config: ConfigService,
  ) {}

  /** 首次启动：表为空时从 MCP_SERVERS 环境变量播种入库（之后以 DB 为准）。 */
  async onModuleInit(): Promise<void> {
    const count = await this.repo.count();
    if (count > 0) return;
    const seed = parseMcpServers(this.config.get<string>('MCP_SERVERS'));
    for (let i = 0; i < seed.length; i++) {
      const s = seed[i];
      await this.repo.save(
        this.repo.create({
          code: s.id,
          name: s.name ?? s.id,
          transport: s.transport,
          url: s.url ?? '',
          headers: s.headers ? JSON.stringify(s.headers) : undefined,
          command: s.command ?? '',
          args: s.args ? JSON.stringify(s.args) : undefined,
          env: s.env ? JSON.stringify(s.env) : undefined,
          enabled: true,
          sortOrder: seed.length - i,
        }),
      );
    }
    if (seed.length > 0) {
      this.logger.log(`从 MCP_SERVERS 播种 ${seed.length} 个 MCP server`);
    }
  }

  /** 配置变更后调用：清掉服务器 / 工具缓存，并关闭所有现存连接。 */
  invalidate(): void {
    this.serversCache = undefined;
    this.toolCache = undefined;
    for (const c of this.clients.values()) {
      c.close().catch(() => undefined);
    }
    this.clients.clear();
  }

  /** 加载启用中的 server（30s 缓存，写操作经 invalidate 失效）。 */
  private async loadServers(): Promise<McpServerConfig[]> {
    if (
      this.serversCache &&
      Date.now() - this.serversCache.at < SERVERS_TTL_MS
    ) {
      return this.serversCache.list;
    }
    const rows = await this.repo.find({
      where: { enabled: true },
      order: { sortOrder: 'DESC', id: 'ASC' },
    });
    const list = rows
      .map((r) => this.toConfig(r))
      .filter((c) => this.isValid(c));
    this.serversCache = { at: Date.now(), list };
    return list;
  }

  private toConfig(e: McpServerEntity): McpServerConfig {
    return {
      id: e.code,
      name: e.name || e.code,
      transport: e.transport === 'stdio' ? 'stdio' : 'http',
      url: e.url || undefined,
      headers: this.parseJson<Record<string, string>>(e.headers),
      command: e.command || undefined,
      args: this.parseJson<string[]>(e.args),
      env: this.parseJson<Record<string, string>>(e.env),
      enabled: e.enabled,
    };
  }

  private isValid(c: McpServerConfig): boolean {
    if (c.transport === 'http') return !!c.url && c.url.trim().length > 0;
    return !!c.command && c.command.trim().length > 0;
  }

  private parseJson<T>(raw: string | null | undefined): T | undefined {
    if (!raw) return undefined;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return undefined;
    }
  }

  /** server 概览（不触发连接）。 */
  async serverSummaries(): Promise<
    { id: string; name: string; transport: string }[]
  > {
    const servers = await this.loadServers();
    return servers.map((s) => ({
      id: s.id,
      name: s.name ?? s.id,
      transport: s.transport,
    }));
  }

  private clientFor(cfg: McpServerConfig): McpClient {
    const existing = this.clients.get(cfg.id);
    if (existing) return existing;
    const client: McpClient =
      cfg.transport === 'http'
        ? new HttpMcpClient(cfg.url!, cfg.headers ?? {})
        : new StdioMcpClient(cfg.command!, cfg.args ?? [], cfg.env ?? {});
    this.clients.set(cfg.id, client);
    return client;
  }

  /** 聚合所有 server 的工具（带 60s 缓存）。单个 server 失败不影响其它。 */
  async listTools(force = false): Promise<AggregatedTool[]> {
    if (
      !force &&
      this.toolCache &&
      Date.now() - this.toolCache.at < TOOLS_TTL_MS
    ) {
      return this.toolCache.tools;
    }
    const out: AggregatedTool[] = [];
    this.toolIndex.clear();
    for (const cfg of await this.loadServers()) {
      try {
        const client = this.clientFor(cfg);
        const specs = await client.listTools();
        for (const spec of specs) {
          this.addTool(
            out,
            cfg.id,
            spec.name,
            spec.description,
            spec.inputSchema,
          );
        }
        // Resources / Prompts 合成工具（item 7），按 server 声明的能力暴露。
        const caps = client.capabilities;
        if (caps.resources != null) {
          this.addTool(
            out,
            cfg.id,
            SYN_RESOURCES_LIST,
            '列出该来源可读的资源',
            {
              type: 'object',
              properties: {},
            },
          );
          this.addTool(
            out,
            cfg.id,
            SYN_RESOURCES_READ,
            '读取指定 uri 的资源正文',
            {
              type: 'object',
              properties: { uri: { type: 'string', description: '资源 uri' } },
              required: ['uri'],
            },
          );
        }
        if (caps.prompts != null) {
          this.addTool(
            out,
            cfg.id,
            SYN_PROMPTS_LIST,
            '列出该来源的提示词模板',
            {
              type: 'object',
              properties: {},
            },
          );
          this.addTool(
            out,
            cfg.id,
            SYN_PROMPTS_GET,
            '取指定提示词模板渲染后的文本',
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: '提示词模板名' },
                arguments: { type: 'object', description: '模板参数（可选）' },
              },
              required: ['name'],
            },
          );
        }
      } catch (e) {
        this.logger.warn(
          `MCP server "${cfg.id}" 列工具失败：${(e as Error).message}`,
        );
      }
    }
    this.toolCache = { at: Date.now(), tools: out };
    return out;
  }

  private addTool(
    out: AggregatedTool[],
    serverId: string,
    rawName: string,
    description: string | undefined,
    schema: unknown,
  ): void {
    const name = `${TOOL_PREFIX}${serverId}__${rawName}`;
    this.toolIndex.set(name, { serverId, rawName });
    out.push({
      name,
      description,
      parameters: (schema as Record<string, unknown>) ?? {
        type: 'object',
        properties: {},
      },
      serverId,
    });
  }

  /** 执行一次工具调用，按前缀路由到对应 server。返回纯文本结果。 */
  async callTool(name: string, args: Record<string, unknown>): Promise<string> {
    let route = this.toolIndex.get(name);
    if (!route) {
      // 缓存未命中（如重启后首调）：重建索引再试一次。
      await this.listTools(true);
      route = this.toolIndex.get(name);
    }
    if (!route) {
      // 兜底：按前缀解析 mcp__<id>__<rawName>。
      const parsed = this.parseName(name);
      if (!parsed) return `错误：未知的 MCP 工具 "${name}"`;
      route = parsed;
    }
    const servers = await this.loadServers();
    const cfg = servers.find((s) => s.id === route.serverId);
    if (!cfg) return `错误：MCP server "${route.serverId}" 未配置或已禁用`;
    try {
      const client = this.clientFor(cfg);
      const a = args ?? {};
      const str = (v: unknown): string => (typeof v === 'string' ? v : '');
      switch (route.rawName) {
        case SYN_RESOURCES_LIST:
          return JSON.stringify(await client.listResources());
        case SYN_RESOURCES_READ:
          return client.readResource(str(a.uri));
        case SYN_PROMPTS_LIST:
          return JSON.stringify(await client.listPrompts());
        case SYN_PROMPTS_GET:
          return client.getPrompt(
            str(a.name),
            (a.arguments as Record<string, unknown>) ?? {},
          );
        default:
          return await client.callTool(route.rawName, a);
      }
    } catch (e) {
      return `MCP 工具 "${name}" 执行失败：${(e as Error).message}`;
    }
  }

  private parseName(
    name: string,
  ): { serverId: string; rawName: string } | null {
    if (!name.startsWith(TOOL_PREFIX)) return null;
    const rest = name.slice(TOOL_PREFIX.length);
    const sep = rest.indexOf('__');
    if (sep <= 0) return null;
    return {
      serverId: rest.slice(0, sep),
      rawName: rest.slice(sep + 2),
    };
  }

  async onModuleDestroy(): Promise<void> {
    for (const client of this.clients.values()) {
      await client.close().catch(() => undefined);
    }
    this.clients.clear();
  }
}
