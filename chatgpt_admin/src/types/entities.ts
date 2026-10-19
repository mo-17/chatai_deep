export interface AdminUser {
  id: number;
  userName: string;
  avatar?: string;
}

export interface AppUser {
  id: number;
  userName: string;
  avatar?: string;
  imoocId?: string;
  role: 'user' | 'admin';
  banned: boolean;
  email?: string | null;
  countryCode?: string | null;
  phoneNumber?: string | null;
}

export interface Banner {
  id: number;
  title: string;
  subtitle?: string;
  cover?: string;
  url?: string;
  sticky: number;
  enabled: boolean;
  type: string;
  createTime: string;
  updateTime: string;
}

export interface AppVersion {
  rolloutPercent: number;
  rolloutSalt: string;
  artifacts: Record<string,{url:string;sha256:string;bytes:number}>;
  id: number;
  versionName: string;
  versionCode: number;
  url?: string;
  sha256?: string | null;
  description?: string;
  cid: string;
  forceUpdate: boolean;
  enabled: boolean;
  createTime: string;
  updateTime: string;
}

export interface UsageRecord {
  id: number;
  userId: number;
  userName: string;
  provider: string;
  model: string;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  createdAt: string;
}

export interface UsageSummary {
  today: { tokens: number; calls: number };
  week: { tokens: number; calls: number };
  month: { tokens: number; calls: number };
  all: { tokens: number; calls: number };
  userCount: number;
  activeToday: number;
}
