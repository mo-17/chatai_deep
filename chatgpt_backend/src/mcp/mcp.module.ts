import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { McpController } from './mcp.controller';
import { McpService } from './mcp.service';
import { AdminMcpController } from './admin-mcp.controller';
import { AdminMcpService } from './admin-mcp.service';
import { McpServerEntity } from './mcp-server.entity';

/// MCP Host 模块（方案 B）。server 列表存 DB（item 4），后台 CRUD 维护。
@Module({
  imports: [TypeOrmModule.forFeature([McpServerEntity])],
  controllers: [McpController, AdminMcpController],
  providers: [McpService, AdminMcpService],
  exports: [McpService],
})
export class McpModule {}
