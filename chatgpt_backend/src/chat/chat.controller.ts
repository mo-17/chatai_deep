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
  ParseIntPipe,
} from '@nestjs/common';
import type { Response } from 'express';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { JwtGuard } from '../auth/jwt.guard';
import { AdminGuard } from '../auth/admin.guard';
import { ChatService } from './chat.service';
import { CompletionBodyDto } from './dto/completion-body.dto';
import { SaveMessagesDto } from './dto/save-messages.dto';
import {
  CreateConversationDto,
  UpdateConversationDto,
} from './dto/conversation-body.dto';
import { safeUpstreamPayloadFromError } from './upstream-error';

@Controller('uapi/chat')
export class ChatController {
  constructor(private readonly svc: ChatService) {}

  // --- Conversation CRUD (admin only) ---

  @Get('conversations')
  @UseGuards(AdminGuard)
  async listConversations(@Req() req: AuthenticatedRequest) {
    const data = await this.svc.listConversations(req.user!.userId);
    return { code: 0, data, ownerId: req.user!.userId };
  }

  @Post('conversations')
  @HttpCode(200)
  @UseGuards(AdminGuard)
  async createConversation(
    @Req() req: AuthenticatedRequest,
    @Body() body: CreateConversationDto,
  ) {
    const data = await this.svc.createConversation(
      req.user!.userId,
      body.model,
      body.providerCode,
    );
    return { code: 0, data };
  }

  @Patch('conversations/:id')
  @UseGuards(AdminGuard)
  async updateConversation(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseIntPipe) id: number,
    @Body() body: UpdateConversationDto,
  ) {
    await this.svc.updateConversation(req.user!.userId, id, body);
    return { code: 0, data: null };
  }

  @Delete('conversations/:id')
  @UseGuards(AdminGuard)
  async deleteConversation(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseIntPipe) id: number,
  ) {
    await this.svc.deleteConversation(req.user!.userId, id);
    return { code: 0, data: null };
  }

  // --- Message CRUD (admin only) ---

  @Get('conversations/:id/messages')
  @UseGuards(AdminGuard)
  async listMessages(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseIntPipe) id: number,
  ) {
    const data = await this.svc.listMessages(req.user!.userId, id);
    return { code: 0, data, ownerId: req.user!.userId, conversationId: id };
  }

  @Post('conversations/:id/messages')
  @HttpCode(200)
  @UseGuards(AdminGuard)
  async saveMessages(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseIntPipe) id: number,
    @Body() body: SaveMessagesDto,
  ) {
    await this.svc.saveMessages(req.user!.userId, id, body.messages);
    return {
      code: 0,
      data: null,
      ownerId: req.user!.userId,
      conversationId: id,
    };
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
    const clientAbort = new AbortController();
    const abortClient = () => clientAbort.abort();
    req.on('aborted', abortClient);
    res.on('close', abortClient);
    if (req.aborted || res.destroyed) abortClient();

    try {
      await this.svc.completeStream(
        req.user!.userId,
        body,
        res,
        clientAbort.signal,
      );
    } catch (err: unknown) {
      if (clientAbort.signal.aborted || res.destroyed || res.writableEnded) {
        return;
      }
      const payload = safeUpstreamPayloadFromError(err);
      if (!res.headersSent) {
        if (payload.retryAfterSeconds !== undefined) {
          res.setHeader('Retry-After', String(payload.retryAfterSeconds));
        }
        res.status(payload.statusCode).json(payload);
      } else {
        res.write(`event: error\ndata: ${JSON.stringify(payload)}\n\n`);
        res.end();
      }
    } finally {
      req.off('aborted', abortClient);
      res.off('close', abortClient);
    }
  }
}
