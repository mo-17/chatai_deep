'use client';
import { useEffect } from 'react';
export default function MicrosoftResultPage() {
  useEffect(() => { window.opener?.postMessage('ms-smtp-returned', window.location.origin); }, []);
  return <main className="p-8 space-y-4"><h1 className="text-xl font-bold">微软授权已返回</h1>
    <p>请回到发起授权的后台窗口，刷新状态并完成授权。此页面不接收授权码。</p>
    <p>如果原窗口已关闭或登录会话改变，请在 SMTP 服务商页重新发起。</p>
    <button className="auth-button" onClick={() => window.close()}>关闭此窗口</button></main>;
}
