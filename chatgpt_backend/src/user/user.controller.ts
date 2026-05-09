import {
  Controller,
  Post,
  Get,
  Body,
  Res,
  HttpCode,
} from '@nestjs/common';
import type { Response } from 'express';
import { UserService } from './user.service';

@Controller('uapi/user')
export class UserController {
  constructor(private readonly userService: UserService) {}

  @Post('login')
  @HttpCode(200)
  async login(@Body() body?: { userName?: string; password?: string }) {
    const u = body?.userName || '';
    const p = body?.password || '';
    return this.userService.login(u, p);
  }

  @Post('registration')
  @HttpCode(200)
  async register(@Body() body?: { userName?: string; password?: string }) {
    const u = body?.userName || '';
    const p = body?.password || '';
    return this.userService.register(u, p);
  }

  @Get('register-page')
  registerPage(@Res() res: Response) {
    res.send(`<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>注册账号</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, sans-serif; background: #1a1a2e; color: #eee; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
    .container { background: #16213e; padding: 40px; border-radius: 12px; width: 100%; max-width: 400px; }
    h1 { text-align: center; margin-bottom: 30px; color: #0f3460; }
    input { width: 100%; padding: 12px; margin-bottom: 16px; border: 1px solid #0f3460; border-radius: 6px; background: #1a1a2e; color: #eee; font-size: 16px; }
    button { width: 100%; padding: 12px; background: #e94560; color: white; border: none; border-radius: 6px; font-size: 16px; cursor: pointer; }
    button:hover { background: #d63851; }
    #result { margin-top: 16px; padding: 12px; border-radius: 6px; text-align: center; }
    .success { background: #1b5e20; }
    .error { background: #b71c1c; }
    .tip { margin-top: 20px; text-align: center; font-size: 14px; color: #888; }
  </style>
</head>
<body>
  <div class="container">
    <h1>ChatGPT Flutter</h1>
    <input id="userName" placeholder="请输入账号" />
    <input id="password" type="password" placeholder="请输入密码" />
    <button onclick="register()">注册</button>
    <div id="result"></div>
    <div class="tip">注册成功后返回 App 登录</div>
  </div>
  <script>
    async function register() {
      const userName = document.getElementById('userName').value;
      const password = document.getElementById('password').value;
      const result = document.getElementById('result');
      if (!userName || !password) {
        result.className = 'error';
        result.textContent = '请输入账号和密码';
        return;
      }
      try {
        const resp = await fetch('/uapi/user/registration', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ userName, password })
        });
        const data = await resp.json();
        if (data.code === 0) {
          result.className = 'success';
          result.textContent = '注册成功！请返回 App 登录';
        } else {
          result.className = 'error';
          result.textContent = data.message || '注册失败';
        }
      } catch (e) {
        result.className = 'error';
        result.textContent = '网络错误：' + e.message;
      }
    }
  </script>
</body>
</html>`);
  }
}
