'use client';

import { useEffect, useState, useMemo, useRef } from 'react';
import Image from 'next/image';
import {
  Card, CardBody, CardHeader, Button, Select, SelectItem, Switch, Spinner,
} from '@heroui/react';
import { Upload } from 'lucide-react';
import { useGlobalConfig, useProviders, useModels, useAiMutations } from '@/hooks/useAi';
import { aiApi } from '@/lib/api/ai';

const AVATAR_BASE = '/uploads/avatars/';

export default function AiGlobalPage() {
  const { data: config, isLoading } = useGlobalConfig();
  const { data: providers } = useProviders();
  const { data: allModels } = useModels();
  const { updateGlobal } = useAiMutations();

  const [providerCode, setProviderCode] = useState('');
  const [modelId, setModelId] = useState('');
  const [catalogPublic, setCatalogPublic] = useState(true);
  const [saved, setSaved] = useState(false);
  const [avatarUploading, setAvatarUploading] = useState(false);
  const [avatarError, setAvatarError] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (config) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setProviderCode(config.defaultProviderCode);
       
      setModelId(config.defaultModelId);
       
      setCatalogPublic(config.catalogPublic);
    }
  }, [config]);

  const avatarUrl = config?.avatarPath ? `${AVATAR_BASE}${config.avatarPath}` : null;

  const handleAvatarUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 2 * 1024 * 1024) {
      setAvatarError('文件不能超过 2MB');
      return;
    }
    setAvatarError('');
    setAvatarUploading(true);
    try {
      const reader = new FileReader();
      const base64 = await new Promise<string>((resolve, reject) => {
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      await aiApi.uploadAvatar(base64);
      // 刷新页面以显示新头像
      window.location.reload();
    } catch (err: unknown) {
      setAvatarError((err as Error)?.message || '上传失败');
    } finally {
      setAvatarUploading(false);
    }
  };

  const enabledProviders = useMemo(
    () => (providers || []).filter((p) => p.enabled),
    [providers],
  );

  const filteredModels = useMemo(
    () => (allModels || []).filter(
      (m) => m.enabled && m.providerCode === providerCode,
    ),
    [allModels, providerCode],
  );

  const handleSave = () => {
    updateGlobal.mutate(
      { defaultProviderCode: providerCode, defaultModelId: modelId, catalogPublic },
      {
        onSuccess: () => {
          setSaved(true);
          setTimeout(() => setSaved(false), 2000);
        },
      },
    );
  };

  if (isLoading) {
    return <div className="flex justify-center py-20"><Spinner /></div>;
  }

  return (
    <div className="max-w-lg">
      <h1 className="text-xl font-bold mb-6">全局 AI 配置</h1>

      <Card>
        <CardHeader><p className="font-semibold">默认兜底设置</p></CardHeader>
        <CardBody className="space-y-4">
          <Select
            label="默认服务商"
            selectedKeys={providerCode ? [providerCode] : []}
            onSelectionChange={(keys) => {
              const val = Array.from(keys as Set<string>)[0];
              setProviderCode(val);
              setModelId('');
            }}
          >
            {enabledProviders.map((p) => (
              <SelectItem key={p.code}>{p.displayName}</SelectItem>
            ))}
          </Select>

          <Select
            label="默认模型"
            selectedKeys={modelId ? [modelId] : []}
            onSelectionChange={(keys) => {
              setModelId(Array.from(keys as Set<string>)[0]);
            }}
            isDisabled={!providerCode}
          >
            {filteredModels.map((m) => (
              <SelectItem key={m.modelId}>{m.displayName} ({m.modelId})</SelectItem>
            ))}
          </Select>

          <div className="border-t pt-4">
            <Switch
              isSelected={catalogPublic}
              onValueChange={setCatalogPublic}
            >
              <div>
                <div className="font-medium">允许 App 拉取模型清单</div>
                <div className="text-xs text-default-400">
                  关闭后 App 端 /uapi/ai/catalog 返回 403，App 将仅显示本地硬编码清单
                </div>
              </div>
            </Switch>
          </div>
        </CardBody>
      </Card>

      <Card className="mt-6">
        <CardHeader><p className="font-semibold">AI 头像</p></CardHeader>
        <CardBody>
          <div className="flex items-center gap-4">
            {avatarUrl ? (
              <Image
                src={avatarUrl}
                alt="AI avatar"
                width={64}
                height={64}
                unoptimized
                className="w-16 h-16 rounded-lg object-cover border border-default-300"
              />
            ) : (
              <div className="w-16 h-16 rounded-lg bg-[#2E7D32] flex items-center justify-center text-white font-bold text-xl">
                AI
              </div>
            )}
            <div className="flex-1">
              <input
                ref={fileRef}
                type="file"
                accept="image/*"
                className="hidden"
                onChange={handleAvatarUpload}
              />
              <Button
                size="sm"
                variant="bordered"
                startContent={<Upload size={14} />}
                isLoading={avatarUploading}
                onPress={() => fileRef.current?.click()}
              >
                上传头像
              </Button>
              <p className="text-xs text-default-400 mt-1">
                支持 PNG / JPG / WebP，最大 2MB。上传后 App 端对话列表将显示此头像。
              </p>
              {avatarError && (
                <p className="text-xs text-danger mt-1">{avatarError}</p>
              )}
            </div>
          </div>
        </CardBody>
      </Card>

      <div className="mt-6 flex items-center gap-3">
        <Button
          color="primary"
          isLoading={updateGlobal.isPending}
          onPress={handleSave}
        >
          保存
        </Button>
        {saved && (
          <span className="text-sm text-success">✓ 保存成功</span>
        )}
        {updateGlobal.isError && (
          <span className="text-sm text-danger">
            ✗ 保存失败：{(updateGlobal.error as Error)?.message}
          </span>
        )}
      </div>
    </div>
  );
}
