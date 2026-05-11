/** 抽象 AuthUser，宿主项目的 User 实体通过 IUserResolver 桥接至此类型 */
export interface AuthUser {
  id: number;
  userName: string;
  email: string | null;
  emailVerifiedAt: Date | null;
  countryCode: string | null;
  phoneNumber: string | null;
  phoneVerifiedAt: Date | null;
  huaweiUnionId: string | null;
  huaweiOpenId: string | null;
  appleSubject: string | null;
  appleEmailRelay: string | null;
  password: string | null;
  avatar?: string | null;
  role: string;
  banned: boolean;
}

export interface CreateUserInput {
  userName?: string;
  email?: string;
  countryCode?: string;
  phoneNumber?: string;
  password?: string;
  role?: string;
}

export type ThirdPartyProvider = 'huawei' | 'apple';

export type AuthChannel = 'email' | 'sms';
