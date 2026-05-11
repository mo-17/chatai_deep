import {
  Controller,
  Post,
  Get,
  Patch,
  Delete,
  Req,
  Body,
  Param,
  Res,
  UseGuards,
  HttpCode,
} from '@nestjs/common';
import type { Response } from 'express';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { JwtGuard } from '../auth/jwt.guard';
import { AdminGuard } from '../auth/admin.guard';
import { ChatService } from './chat.service';
import { CompletionBodyDto } from './dto/completion-body.dto';

@Controller('uapi/chat')
export class ChatController {
  constructor(private readonly svc: ChatService) {}

  // --- Conversation CRUD (admin only) ---

  @Get('conversations')
  @UseGuards(AdminGuard)
  async listConversations(@Req() req: AuthenticatedRequest) {
    const data = await this.svc.listConversations(req.user!.userId);
    return { code: 0, data };
  }

  @Post('conversations')
  @HttpCode(200)
  @UseGuards(AdminGuard)
  async createConversation(
    @Req() req: AuthenticatedRequest,
    @Body() body: { model: string },
  ) {
    const data = await this.svc.createConversation(
      req.user!.userId,
      body.model || '',
    );
    return { code: 0, data };
  }

  @Patch('conversations/:id')
  @UseGuards(AdminGuard)
  async updateConversation(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Body() body: { title: string },
  ) {
    await this.svc.updateConversation(
      req.user!.userId,
      parseInt(id),
      body.title,
    );
    return { code: 0, data: null };
  }

  @Delete('conversations/:id')
  @UseGuards(AdminGuard)
  async deleteConversation(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
  ) {
    await this.svc.deleteConversation(req.user!.userId, parseInt(id));
    return { code: 0, data: null };
  }

  // --- Message CRUD (admin only) ---

  @Get('conversations/:id/messages')
  @UseGuards(AdminGuard)
  async listMessages(@Param('id') id: string) {
    const data = await this.svc.listMessages(parseInt(id));
    return { code: 0, data };
  }

  @Post('conversations/:id/messages')
  @HttpCode(200)
  @UseGuards(AdminGuard)
  async saveMessages(
    @Param('id') id: string,
    @Body()
    body: { messages: { role: 'user' | 'assistant'; content: string }[] },
  ) {
    await this.svc.saveMessages(parseInt(id), body.messages || []);
    return { code: 0, data: null };
  }

  // --- Completions ---

  @Post('completions')
  @HttpCode(200)
  @UseGuards(JwtGuard)
  async completions(
    @Req() req: AuthenticatedRequest,
    @Body() body: CompletionBodyDto,
  ) {
    const data = await this.svc.complete(req.user!.userId, body);
    return { code: 0, data, extra: {} };
  }

  @Post('completions/stream')
  @UseGuards(JwtGuard)
  async completionsStream(
    @Req() req: AuthenticatedRequest,
    @Body() body: CompletionBodyDto,
    @Res() res: Response,
  ) {
    try {
      await this.svc.completeStream(req.user!.userId, body, res);
    } catch (err: unknown) {
      const e = err as { status?: number; message?: string };
      if (!res.headersSent) {
        res.status(e.status || 502).json({
          code: -1,
          message: e.message || '流式请求失败',
        });
      } else {
        res.write(
          `event: error\ndata: ${JSON.stringify({ message: e.message ?? '上游错误' })}\n\n`,
        );
        res.end();
      }
    }
  }
}
