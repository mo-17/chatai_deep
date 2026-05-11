'use client';

import { useState, useEffect } from 'react';
import { Button, Switch, Input, Spinner } from '@nextui-org/react';
import { fetchAuthSettings, updateAuthSettings } from '@/lib/api/auth-admin';
import type { AuthSettings } from '@/lib/api/auth-admin';

export default function AuthSettingsPage() {
  const [settings, setSettings] = useState<AuthSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fetchAuthSettings().then(setSettings).catch(() => {}).finally(() => setLoading(false));
  }, []);

  const update = async (patch: Partial<AuthSettings>) => {
    if (!settings) return;
    const updated = { ...settings, ...patch };
    setSettings(updated);
    setSaving(true);
    try { setSettings(await updateAuthSettings(patch)); } catch (_) {}
    setSaving(false);
  };

  if (loading) return <Spinner />;
  if (!settings) return <div className="text-danger">加载失败</div>;

  return (
    <div className="space-y-6 max-w-2xl">
      <h1 className="text-xl font-bold">认证策略设置</h1>

      <section className="space-y-4 bg-content1 p-4 rounded-lg">
        <h2 className="font-semibold">华为账号</h2>
        <Switch isSelected={settings.huaweiGetAuthCodeEnabled} onValueChange={v => update({ huaweiGetAuthCodeEnabled: v })}>Authorization Code 登录</Switch>
        <Switch isSelected={settings.huaweiQuickLoginEnabled} onValueChange={v => update({ huaweiQuickLoginEnabled: v })}>一键登录 (Quick Login)</Switch>
        <div className="flex items-center gap-2">
          <span className="text-sm">主流程：</span>
          <select className="border rounded px-2 py-1 text-sm" value={settings.huaweiPrimaryFlow} onChange={e => update({ huaweiPrimaryFlow: e.target.value })}>
            <option value="getAuthCode">getAuthCode</option>
            <option value="quickLogin">quickLogin</option>
          </select>
        </div>
      </section>

      <section className="space-y-4 bg-content1 p-4 rounded-lg">
        <h2 className="font-semibold">Apple 登录</h2>
        <Switch isSelected={settings.appleSignInEnabled} onValueChange={v => update({ appleSignInEnabled: v })}>Sign in with Apple</Switch>
      </section>

      <section className="space-y-4 bg-content1 p-4 rounded-lg">
        <h2 className="font-semibold">验证码策略</h2>
        <Input label="验证码有效期（秒）" type="number" value={String(settings.codeTtlSeconds)} onChange={e => update({ codeTtlSeconds: Number(e.target.value) })} className="max-w-xs" />
        <Input label="最大重试次数" type="number" value={String(settings.codeMaxAttempts)} onChange={e => update({ codeMaxAttempts: Number(e.target.value) })} className="max-w-xs" />
        <Input label="当日最大发送量" type="number" value={String(settings.codeDailyLimit)} onChange={e => update({ codeDailyLimit: Number(e.target.value) })} className="max-w-xs" />
        <Input label="重发间隔（秒）" type="number" value={String(settings.codeResendSeconds)} onChange={e => update({ codeResendSeconds: Number(e.target.value) })} className="max-w-xs" />
        <Input label="单 IP 每小时上限" type="number" value={String(settings.codeHourlyLimitPerIp)} onChange={e => update({ codeHourlyLimitPerIp: Number(e.target.value) })} className="max-w-xs" />
        <Switch isSelected={settings.smsMockHighlight} onValueChange={v => update({ smsMockHighlight: v })}>SMS Mock 高亮</Switch>
      </section>

      {saving && <div className="text-sm text-default-500">正在保存...</div>}
    </div>
  );
}
