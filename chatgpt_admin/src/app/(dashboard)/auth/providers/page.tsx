'use client';

import { useState, useEffect, useMemo } from 'react';
import {
  Card, CardBody, CardHeader, CardFooter,
  Button, Chip, Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
  Input, Switch, Autocomplete, AutocompleteItem, AutocompleteSection,
  Spinner,
} from '@heroui/react';
import { Wrench, Pencil, CircleAlert, ExternalLink } from 'lucide-react';
import { addToast } from '@heroui/react';
import {
  fetchProviders, updateProvider, activateProvider, testProvider,
  type SmtpProvider, type SmtpProviderKey,
} from '@/lib/api/auth-admin';
import { SMTP_PRESETS, GROUP_LABEL, matchPreset, type SmtpPreset, type SmtpPresetGroup } from '@/lib/smtp-presets';

interface SlotMeta {
  key: SmtpProviderKey;
  displayName: string;
  /** 该 slot 的简介 */
  description: string;
  /** generic 走原生 SMTP，允许从预设里选服务商；另外两个 host 基本固定 */
  allowPresets: boolean;
  /** 推荐默认值（首次配置时给个起点） */
  defaults?: { host: string; port: number; secure: boolean };
}

const SLOT_META: SlotMeta[] = [
  {
    key: 'generic',
    displayName: '通用 SMTP',
    description: '原生 SMTP，可接 Gmail/QQ/163/Outlook 等任意服务商。',
    allowPresets: true,
  },
  {
    key: 'aliyun_dm',
    displayName: '阿里云邮件推送 (DM)',
    description: '阿里云 DirectMail 的 SMTP 接入，需提前在控制台创建发信地址与发信域名。',
    allowPresets: false,
    defaults: { host: 'smtpdm.aliyun.com', port: 465, secure: true },
  },
  {
    key: 'tencent_ses',
    displayName: '腾讯云 SES',
    description: '腾讯云邮件推送 (SES) 的 SMTP 接入，需在控制台开通服务并配置发信域名。',
    allowPresets: false,
    defaults: { host: 'smtp.ses.tencent-cloud.com', port: 465, secure: true },
  },
];

type FormState = Partial<SmtpProvider> & { password?: string };

function makeEmptyForm(meta: SlotMeta): FormState {
  return {
    key: meta.key,
    displayName: meta.displayName,
    host: meta.defaults?.host ?? '',
    port: meta.defaults?.port ?? 587,
    secure: meta.defaults?.secure ?? false,
    username: '',
    password: '',
    fromName: '',
    fromAddress: '',
  };
}

export default function AuthProvidersPage() {
  const [providers, setProviders] = useState<SmtpProvider[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyKey, setBusyKey] = useState<SmtpProviderKey | null>(null);

  // 编辑弹窗
  const [editorMeta, setEditorMeta] = useState<SlotMeta | null>(null);
  const [form, setForm] = useState<FormState>({});
  const [presetId, setPresetId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // 测试弹窗
  const [testMeta, setTestMeta] = useState<SlotMeta | null>(null);
  const [testTo, setTestTo] = useState('');
  const [testing, setTesting] = useState(false);

  const [refreshKey, setRefreshKey] = useState(0);
  const reload = () => { setLoading(true); setRefreshKey(k => k + 1); };

  useEffect(() => {
    fetchProviders()
      .then(setProviders)
      .catch((e: Error) => addToast({ title: `加载失败：${e.message}`, severity: 'danger' }))
      .finally(() => setLoading(false));
  }, [refreshKey]);

  const providerByKey = useMemo(() => {
    const map = new Map<SmtpProviderKey, SmtpProvider>();
    providers.forEach(p => map.set(p.key, p));
    return map;
  }, [providers]);

  const currentPreset: SmtpPreset | null = useMemo(() => {
    if (!presetId) return null;
    return SMTP_PRESETS.find(p => p.id === presetId) ?? null;
  }, [presetId]);

  const openEditor = (meta: SlotMeta) => {
    const existing = providerByKey.get(meta.key);
    if (existing) {
      // 已有配置：回显（密码留空，不修改），尝试反查预设
      setForm({
        key: existing.key,
        displayName: existing.displayName,
        host: existing.host,
        port: existing.port,
        secure: existing.secure,
        username: existing.username,
        password: '',
        fromName: existing.fromName,
        fromAddress: existing.fromAddress,
      });
      const matched = meta.allowPresets ? matchPreset(existing.host, existing.port, existing.secure) : null;
      setPresetId(matched?.id ?? null);
    } else {
      setForm(makeEmptyForm(meta));
      setPresetId(null);
    }
    setEditorMeta(meta);
  };

  const applyPreset = (id: string | null) => {
    setPresetId(id);
    if (!id) return;
    const preset = SMTP_PRESETS.find(p => p.id === id);
    if (!preset) return;
    setForm(f => ({
      ...f,
      host: preset.host,
      port: preset.port,
      secure: preset.secure,
    }));
  };

  const handleSave = async () => {
    if (!editorMeta) return;
    // state 优先；若 state 空但 DOM 有值（autofill / blur 未同步），用 DOM 值兜底
    const readField = (name: string, stateVal: string | undefined) => {
      const fromState = (stateVal ?? '').trim();
      if (fromState) return fromState;
      const el = document.querySelector<HTMLInputElement>(`input[name="${name}"]`);
      return (el?.value ?? '').trim();
    };
    const host = readField('smtp-host', form.host);
    const username = readField('smtp-username', form.username);
    const fromAddress = readField('smtp-from-address', form.fromAddress);
    const fromName = readField('smtp-from-name', form.fromName);
    const password = form.password ?? ''; // 密码保留原样，不 trim
    const missing: string[] = [];
    if (!host) missing.push('主机');
    if (!username) missing.push('用户名');
    if (!fromAddress) missing.push('发件人地址');
    if (missing.length > 0) {
      // 诊断：把 form 实际值打出来，看是 React state 没同步还是真的没填
      console.warn('[SMTP保存] 校验失败，form 当前值:', {
        host: form.host,
        username: form.username,
        fromAddress: form.fromAddress,
        fromName: form.fromName,
        port: form.port,
      });
      addToast({ title: `以下字段为必填：${missing.join('、')}`, severity: 'danger' });
      return;
    }
    const existing = providerByKey.get(editorMeta.key);
    if (!existing && !password) {
      addToast({ title: '首次配置必须填写 SMTP 密码', severity: 'danger' });
      return;
    }
    setSaving(true);
    try {
      // 后端 PUT 要求该 key 的行已存在；不存在会 404，由 catch 提示
      await updateProvider(editorMeta.key, {
        host,
        port: form.port ?? 587,
        secure: form.secure ?? false,
        username,
        ...(password ? { password } : {}),
        fromName,
        fromAddress,
        displayName: form.displayName ?? editorMeta.displayName,
      });
      setEditorMeta(null);
      addToast({ title: '已保存', severity: 'success' });
      reload();
    } catch (e) {
      addToast({ title: e instanceof Error ? e.message : String(e), severity: 'danger' });
    } finally {
      setSaving(false);
    }
  };

  const handleActivate = async (key: SmtpProviderKey) => {
    setBusyKey(key);
    try {
      await activateProvider(key);
      addToast({ title: '已切换启用的服务商', severity: 'success' });
      reload();
    } catch (e) {
      addToast({ title: e instanceof Error ? e.message : String(e), severity: 'danger' });
    } finally {
      setBusyKey(null);
    }
  };

  const handleTest = async () => {
    if (!testMeta || !testTo) return;
    setTesting(true);
    try {
      const r = await testProvider(testMeta.key, testTo);
      if (r.status === 'ok') {
        addToast({ title: `测试邮件已发送到 ${testTo}`, severity: 'success' });
        setTestMeta(null);
        setTestTo('');
      } else {
        addToast({ title: `测试失败：${r.error ?? '未知错误'}`, severity: 'danger' });
      }
      reload();
    } catch (e) {
      addToast({ title: e instanceof Error ? e.message : String(e), severity: 'danger' });
    } finally {
      setTesting(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <div>
          <h1 className="text-xl font-bold">SMTP 服务商管理</h1>
          <p className="text-sm text-default-500 mt-1">
            同时只能启用一个服务商；另外两个保留为备用。点击「编辑」可填充常见服务商的预设配置。
          </p>
        </div>
      </div>

      {loading ? (
        <div className="flex justify-center py-12"><Spinner /></div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {SLOT_META.map(meta => {
            const p = providerByKey.get(meta.key);
            const configured = !!p;
            return (
              <Card key={meta.key} className={p?.enabled ? 'border-2 border-success' : 'border border-default-200'}>
                <CardHeader className="flex justify-between items-start gap-2 pb-2">
                  <div>
                    <div className="font-semibold flex items-center gap-2">
                      {meta.displayName}
                      {p?.enabled && <Chip size="sm" color="success" variant="flat">已启用</Chip>}
                    </div>
                    <p className="text-xs text-default-500 mt-1">{meta.description}</p>
                  </div>
                </CardHeader>
                <CardBody className="text-sm space-y-1 pt-0">
                  {configured ? (
                    <>
                      <div className="flex gap-1"><span className="text-default-500 w-16 shrink-0">主机：</span><span className="font-mono text-xs">{p!.host}:{p!.port}</span>{p!.secure && <Chip size="sm" variant="flat">SSL</Chip>}</div>
                      <div className="flex gap-1"><span className="text-default-500 w-16 shrink-0">发件人：</span><span className="truncate">{p!.fromName ? `${p!.fromName} <${p!.fromAddress}>` : p!.fromAddress}</span></div>
                      <div className="flex gap-1"><span className="text-default-500 w-16 shrink-0">上次测试：</span>
                        {p!.lastTestedAt ? (
                          <span className={p!.lastTestStatus === 'ok' ? 'text-success' : 'text-danger'}>
                            {p!.lastTestStatus === 'ok' ? '✓ 成功' : '✗ 失败'}
                            <span className="text-default-400 ml-1">{new Date(p!.lastTestedAt).toLocaleString()}</span>
                          </span>
                        ) : <span className="text-default-400">未测试</span>}
                      </div>
                      {p!.lastTestStatus === 'failed' && p!.lastTestError && (
                        <div className="text-xs text-danger-600 bg-danger-50 rounded p-2 mt-1">{p!.lastTestError}</div>
                      )}
                    </>
                  ) : (
                    <div className="text-default-400 italic py-2">未配置</div>
                  )}
                </CardBody>
                <CardFooter className="flex gap-2 pt-2 border-t border-default-100">
                  <Switch
                    size="sm"
                    isSelected={!!p?.enabled}
                    isDisabled={!configured || busyKey === meta.key}
                    onValueChange={() => handleActivate(meta.key)}
                  >
                    启用
                  </Switch>
                  <div className="flex-1" />
                  <Button
                    size="sm" variant="flat"
                    isDisabled={!configured}
                    startContent={<Wrench size={14} />}
                    onPress={() => { setTestMeta(meta); setTestTo(p?.fromAddress ?? ''); }}
                  >测试</Button>
                  <Button
                    size="sm" variant="flat" color="primary"
                    startContent={<Pencil size={14} />}
                    onPress={() => openEditor(meta)}
                  >编辑</Button>
                </CardFooter>
              </Card>
            );
          })}
        </div>
      )}

      {!loading && providers.length === 0 && (
        <div className="bg-warning-50 border border-warning-200 rounded p-4 text-sm space-y-2">
          <div className="font-semibold text-warning-700">数据库还没有 SMTP 服务商行，需先 seed 三条记录</div>
          <p className="text-warning-700">后端当前只暴露「更新/启用/测试」三个动作，没有「新增」接口，所以必须在数据库里先插入这 3 个 slot。可在 Postgres 执行：</p>
          <pre className="bg-warning-100 rounded p-2 text-xs overflow-auto"><code>{`INSERT INTO ak_smtp_providers
  (key, "displayName", host, port, secure, username, "passwordEncrypted", "fromName", "fromAddress", enabled)
VALUES
  ('generic',     '通用 SMTP',          '', 587, false, '', '', '', '', false),
  ('aliyun_dm',   '阿里云邮件推送',     'smtpdm.aliyun.com',           465, true,  '', '', '', '', false),
  ('tencent_ses', '腾讯云 SES',         'smtp.ses.tencent-cloud.com',  465, true,  '', '', '', '', false);`}</code></pre>
          <p className="text-warning-700">插入后刷新本页面再编辑、测试、启用。</p>
        </div>
      )}

      {/* 编辑弹窗 */}
      <Modal isOpen={editorMeta !== null} onClose={() => setEditorMeta(null)} size="2xl" scrollBehavior="inside">
        <ModalContent>
          <ModalHeader className="flex flex-col gap-1">
            <span>配置：{editorMeta?.displayName}</span>
            <span className="text-xs font-normal text-default-500">{editorMeta?.description}</span>
          </ModalHeader>
          <ModalBody className="flex flex-col gap-3">
            {editorMeta?.allowPresets && (
              <>
                <Autocomplete
                  label="服务商预设"
                  placeholder="选择常见服务商（可选）"
                  selectedKey={presetId}
                  onSelectionChange={(k) => applyPreset(k as string | null)}
                  description="选中后会自动填充主机/端口/SSL 设置；账号密码仍需手动填写。"
                >
                  {(['cn', 'intl', 'cloud'] as SmtpPresetGroup[]).map(group => (
                    <AutocompleteSection key={group} title={GROUP_LABEL[group]} showDivider>
                      {SMTP_PRESETS.filter(p => p.group === group).map(p => (
                        <AutocompleteItem key={p.id} textValue={p.name}>
                          <div className="flex flex-col">
                            <span>{p.name}</span>
                            <span className="text-xs text-default-500 font-mono">{p.host}:{p.port}{p.secure ? ' SSL' : ''}</span>
                          </div>
                        </AutocompleteItem>
                      ))}
                    </AutocompleteSection>
                  ))}
                </Autocomplete>

                {currentPreset && (
                  <div className="bg-primary-50 border border-primary-200 rounded p-3 text-xs text-primary-700 space-y-1">
                    <div className="font-semibold flex items-center gap-2">
                      <CircleAlert size={14} /> {currentPreset.name} 配置提示
                    </div>
                    <p>{currentPreset.passwordHint}</p>
                    {currentPreset.helpUrl && (
                      <a href={currentPreset.helpUrl} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 underline">
                        官方说明 <ExternalLink size={12} />
                      </a>
                    )}
                  </div>
                )}
              </>
            )}

            <div className="grid grid-cols-2 gap-3">
              <Input
                label="主机 host" isRequired
                name="smtp-host"
                autoComplete="off"
                value={form.host ?? ''}
                onValueChange={v => setForm(f => ({ ...f, host: v }))}
                onBlur={e => setForm(f => ({ ...f, host: (e.target as HTMLInputElement).value }))}
                placeholder="smtp.example.com"
              />
              <div className="flex gap-2 items-end">
                <Input
                  label="端口" type="number" isRequired
                  value={String(form.port ?? '')}
                  onValueChange={v => setForm(f => ({ ...f, port: Number(v) }))}
                  className="flex-1"
                />
                <div className="pb-2">
                  <Switch
                    size="sm"
                    isSelected={!!form.secure}
                    onValueChange={v => setForm(f => ({ ...f, secure: v }))}
                  >SSL</Switch>
                </div>
              </div>
            </div>

            <Input
              label="用户名" isRequired
              name="smtp-username"
              autoComplete="off"
              value={form.username ?? ''}
              onValueChange={v => setForm(f => ({ ...f, username: v }))}
              onBlur={e => setForm(f => ({ ...f, username: (e.target as HTMLInputElement).value }))}
              placeholder={currentPreset?.usernamePlaceholder ?? '通常是完整邮箱地址'}
            />
            <Input
              label="密码" type="password"
              value={form.password ?? ''}
              onValueChange={v => setForm(f => ({ ...f, password: v }))}
              placeholder={providerByKey.get(editorMeta?.key ?? 'generic') ? '留空表示不修改' : '首次配置必填'}
              description={currentPreset?.passwordHint}
            />

            <div className="grid grid-cols-2 gap-3">
              <Input
                label="发件人名称"
                name="smtp-from-name"
                autoComplete="off"
                value={form.fromName ?? ''}
                onValueChange={v => setForm(f => ({ ...f, fromName: v }))}
                onBlur={e => setForm(f => ({ ...f, fromName: (e.target as HTMLInputElement).value }))}
                placeholder="例如：ChatAI Deep"
              />
              <Input
                label="发件人地址" isRequired
                name="smtp-from-address"
                autoComplete="off"
                value={form.fromAddress ?? ''}
                onValueChange={v => setForm(f => ({ ...f, fromAddress: v }))}
                onBlur={e => setForm(f => ({ ...f, fromAddress: (e.target as HTMLInputElement).value }))}
                placeholder="noreply@yourdomain.com"
              />
            </div>
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setEditorMeta(null)} isDisabled={saving}>取消</Button>
            <Button color="primary" onPress={handleSave} isLoading={saving}>保存</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      {/* 测试弹窗 */}
      <Modal isOpen={testMeta !== null} onClose={() => setTestMeta(null)}>
        <ModalContent>
          <ModalHeader>发送测试邮件</ModalHeader>
          <ModalBody>
            <p className="text-sm text-default-600">使用 <b>{testMeta?.displayName}</b> 发送一封测试邮件，验证当前 SMTP 凭据是否可用。</p>
            <Input
              label="测试收件人"
              type="email"
              value={testTo}
              onValueChange={setTestTo}
              placeholder="your-test@example.com"
              autoFocus
              isRequired
            />
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setTestMeta(null)} isDisabled={testing}>取消</Button>
            <Button color="primary" onPress={handleTest} isLoading={testing} isDisabled={!testTo}>发送</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
