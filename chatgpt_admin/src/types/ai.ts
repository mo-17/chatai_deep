export interface AiProvider {
  id: number;
  code: string;
  displayName: string;
  apiKey: string; // mask from backend
  baseUrl: string;
  modelPrefixes: string | null;
  enabled: boolean;
  sortOrder: number;
  createTime: string;
  updateTime: string;
}

export interface AiModel {
  id: number;
  providerId: number;
  modelId: string;
  displayName: string;
  description: string | null;
  enabled: boolean;
  isDefault: boolean;
  sortOrder: number;
  // 能力位：客户端在家族启发式之上做加法覆盖（强制打开，不会因 false 关位）。
  supportsVision: boolean;
  supportsTool: boolean;
  supportsReasoning: boolean;
  supportsPdf: boolean;
  providerCode?: string;
  inputPrice?: number;
  outputPrice?: number;
  createTime: string;
  updateTime: string;
}

export interface AiGlobalConfig {
  id: number;
  defaultProviderCode: string;
  defaultModelId: string;
  catalogPublic: boolean;
  avatarPath: string | null;
  updateTime: string;
}

export interface TestConnectionResult {
  ok: boolean;
  latencyMs?: number;
  sample?: string;
  error?: string;
}

export interface AiCatalog {
  providers: { code: string; displayName: string }[];
  models: {
    modelId: string;
    displayName: string;
    description: string | null;
    providerCode: string;
    isDefault: boolean;
    sortOrder: number;
    supportsVision: boolean;
    supportsTool: boolean;
    supportsReasoning: boolean;
    supportsPdf: boolean;
  }[];
  default: { providerCode: string; modelId: string };
}
