export interface ModelSyncRow {
  modelId: string;
  displayName: string;
  description?: string;
  supportsVision?: boolean;
  supportsTool?: boolean;
  supportsReasoning?: boolean;
  supportsPdf?: boolean;
  contextWindow?: number;
  maxOutputTokens?: number;
  status: 'new' | 'existing' | 'changed';
  changes: string[];
}
export interface ModelSyncPreview {
  previewId: string;
  expiresAt: number;
  providerId: number;
  providerCode: string;
  format: 'openai' | 'anthropic' | 'gemini';
  rows: ModelSyncRow[];
}
export interface ModelSyncResult {
  providerId: number;
  imported: string[];
  skipped: string[];
}
