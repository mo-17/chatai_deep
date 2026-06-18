import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';
import { Exclude } from 'class-transformer';

/// 后端 MCP server 配置（item 4：从 env 迁移到 DB + 管理后台 CRUD）。
/// headers / env 可能含鉴权 token，标 @Exclude 不随序列化返回。
@Entity('mcp_servers')
export class McpServerEntity {
  @PrimaryGeneratedColumn()
  id: number;

  /// 稳定 code：工具名前缀 mcp__<code>__<tool> 的一部分，也是 call 路由依据。
  @Column({ unique: true })
  code: string;

  @Column({ default: '' })
  name: string;

  /// 'http' | 'stdio'
  @Column({ default: 'http' })
  transport: string;

  // http 传输：
  @Column({ default: '' })
  url: string;

  /// JSON 对象字符串（请求头，可能含鉴权）。
  @Column({ type: 'text', nullable: true })
  @Exclude({ toPlainOnly: true })
  headers: string;

  // stdio 传输：
  @Column({ default: '' })
  command: string;

  /// JSON 数组字符串（命令参数）。
  @Column({ type: 'text', nullable: true })
  args: string;

  /// JSON 对象字符串（子进程环境变量，可能含密钥）。
  @Column({ type: 'text', nullable: true })
  @Exclude({ toPlainOnly: true })
  env: string;

  @Column({ default: true })
  enabled: boolean;

  @Column({ default: 0 })
  sortOrder: number;

  @CreateDateColumn()
  createTime: Date;

  @UpdateDateColumn()
  updateTime: Date;
}
