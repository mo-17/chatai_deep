import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { McpServerEntity } from './mcp-server.entity';
import { McpService } from './mcp.service';
import {
  CreateMcpServerDto,
  UpdateMcpServerDto,
} from './dto/upsert-server.dto';
import { HttpMcpClient, McpClient, StdioMcpClient } from './mcp-client';

/** 管理后台对 MCP server 的增删改查 + 连接测试（item 4，AdminGuard）。 */
@Injectable()
export class AdminMcpService {
  constructor(
    @InjectRepository(McpServerEntity)
    private readonly repo: Repository<McpServerEntity>,
    private readonly mcp: McpService,
  ) {}

  async list() {
    const rows = await this.repo.find({
      order: { sortOrder: 'DESC', id: 'ASC' },
    });
    return { list: rows.map((r) => this.present(r)) };
  }

  async create(dto: CreateMcpServerDto) {
    this.validate(dto.transport, dto.url, dto.command);
    const exists = await this.repo.findOne({ where: { code: dto.code } });
    if (exists) throw new BadRequestException(`code "${dto.code}" 已存在`);
    const entity = this.repo.create({
      code: dto.code,
      name: dto.name ?? dto.code,
      transport: dto.transport,
      url: dto.url ?? '',
      headers: dto.headers ? JSON.stringify(dto.headers) : undefined,
      command: dto.command ?? '',
      args: dto.args ? JSON.stringify(dto.args) : undefined,
      env: dto.env ? JSON.stringify(dto.env) : undefined,
      enabled: dto.enabled ?? true,
      sortOrder: dto.sortOrder ?? 0,
    });
    const saved = await this.repo.save(entity);
    this.mcp.invalidate();
    return this.present(saved);
  }

  async update(id: number, dto: UpdateMcpServerDto) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('MCP server 不存在');
    if (dto.code !== undefined) entity.code = dto.code;
    if (dto.name !== undefined) entity.name = dto.name;
    if (dto.transport !== undefined) entity.transport = dto.transport;
    if (dto.url !== undefined) entity.url = dto.url;
    if (dto.command !== undefined) entity.command = dto.command;
    if (dto.args !== undefined) entity.args = JSON.stringify(dto.args);
    if (dto.enabled !== undefined) entity.enabled = dto.enabled;
    if (dto.sortOrder !== undefined) entity.sortOrder = dto.sortOrder;
    // headers / env 可能含密钥：仅在显式传入时整体替换（与 apiKey 保留逻辑一致）。
    if (dto.headers !== undefined) entity.headers = JSON.stringify(dto.headers);
    if (dto.env !== undefined) entity.env = JSON.stringify(dto.env);
    this.validate(entity.transport, entity.url, entity.command);
    const saved = await this.repo.save(entity);
    this.mcp.invalidate();
    return this.present(saved);
  }

  async remove(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('MCP server 不存在');
    await this.repo.remove(entity);
    this.mcp.invalidate();
  }

  /** 直接连一次该 server 列工具，返回连通性与工具样本。 */
  async test(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('MCP server 不存在');
    const client = this.buildClient(entity);
    try {
      const tools = await client.listTools();
      return {
        ok: true,
        toolCount: tools.length,
        tools: tools.slice(0, 20).map((t) => t.name),
        capabilities: client.capabilities,
      };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    } finally {
      await client.close().catch(() => undefined);
    }
  }

  private buildClient(e: McpServerEntity): McpClient {
    if (e.transport === 'stdio') {
      return new StdioMcpClient(
        e.command,
        this.parse<string[]>(e.args) ?? [],
        this.parse<Record<string, string>>(e.env) ?? {},
      );
    }
    return new HttpMcpClient(
      e.url,
      this.parse<Record<string, string>>(e.headers) ?? {},
    );
  }

  private validate(transport: string, url?: string, command?: string) {
    if (transport === 'http' && !(url && url.trim())) {
      throw new BadRequestException('http 传输需要填写 url');
    }
    if (transport === 'stdio' && !(command && command.trim())) {
      throw new BadRequestException('stdio 传输需要填写 command');
    }
  }

  /** 返回给后台：headers / env 的值脱敏（仅保留 key），避免泄露 token。 */
  private present(e: McpServerEntity) {
    return {
      id: e.id,
      code: e.code,
      name: e.name,
      transport: e.transport,
      url: e.url,
      headers: this.maskObject(e.headers),
      command: e.command,
      args: this.parse<string[]>(e.args) ?? [],
      env: this.maskObject(e.env),
      enabled: e.enabled,
      sortOrder: e.sortOrder,
      createTime: e.createTime,
      updateTime: e.updateTime,
    };
  }

  private maskObject(raw: string | null | undefined): Record<string, string> {
    const obj = this.parse<Record<string, unknown>>(raw);
    if (!obj) return {};
    const out: Record<string, string> = {};
    for (const k of Object.keys(obj)) out[k] = '***';
    return out;
  }

  private parse<T>(raw: string | null | undefined): T | undefined {
    if (!raw) return undefined;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return undefined;
    }
  }
}
