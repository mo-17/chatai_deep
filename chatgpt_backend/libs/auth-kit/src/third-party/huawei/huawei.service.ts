import { Injectable, BadRequestException } from '@nestjs/common';

export interface HuaweiUserInfo {
  unionId: string;
  openId: string;
  displayName?: string;
  avatarUrl?: string;
}

/**
 * 华为账号服务
 *
 * getAuthCode 模式：客户端通过华为 SDK 获取 authCode → 服务端换 accessToken → 拿用户信息
 * quickLogin 模式：客户端通过华为 SDK 获取 accessToken → 服务端直接拿用户信息
 *
 * 当前为桩实现，实际接入需调用华为账号 API：
 *   POST https://oauth-login.cloud.huawei.com/oauth2/v3/token
 *   GET  https://account.cloud.huawei.com/rest.php?nsp_svc=OpenUP.User.getInfo
 */
@Injectable()
export class HuaweiService {
  /**
   * 用 authCode 换取华为用户信息
   */
  verifyAuthCode(authCode: string): Promise<HuaweiUserInfo> {
    // TODO: 接入华为 OAuth token 端点
    // const tokenResp = await httpPost('https://oauth-login.cloud.huawei.com/oauth2/v3/token', {
    //   grant_type: 'authorization_code',
    //   code: authCode,
    //   client_id: process.env.HUAWEI_CLIENT_ID,
    //   client_secret: process.env.HUAWEI_CLIENT_SECRET,
    // });
    // const accessToken = tokenResp.access_token;
    // const userInfo = await httpGet('https://account.cloud.huawei.com/rest.php?...');
    // return { unionId: userInfo.unionID, openId: userInfo.openID, ... };

    if (!authCode) throw new BadRequestException('authCode 不能为空');
    throw new BadRequestException(
      '华为登录尚未配置，请联系管理员设置 HUAWEI_CLIENT_ID',
    );
  }

  /**
   * 用 quickLogin accessToken 换取华为用户信息
   */
  verifyQuickLoginToken(accessToken: string): Promise<HuaweiUserInfo> {
    // TODO: 调用华为用户信息端点验证 accessToken
    if (!accessToken) throw new BadRequestException('accessToken 不能为空');
    throw new BadRequestException('华为一键登录尚未配置，请联系管理员设置');
  }
}
