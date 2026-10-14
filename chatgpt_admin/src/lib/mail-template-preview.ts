export function validTemplate(subject: string, body: string) {
  return !!subject && subject.length <= 200 && !/[\r\n\0]/.test(subject) && !!body && body.length <= 65536 && !body.includes('\0') &&
    [subject, body].every(t => !/\{\{|\}\}/.test(t.replace(/\{\{(code|purposeLabel|ttlMinutes)\}\}/g, '')));
}
const escape = (s: string) => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
export function templatePreview(body: string, purposeLabel: string) {
  const values = { code: '123456', purposeLabel, ttlMinutes: '5' };
  const html = body.replace(/\{\{(code|purposeLabel|ttlMinutes)\}\}/g, (_m, key: keyof typeof values) => escape(values[key]));
  // 仅构造无属性的格式标签，丢弃 meta/link/iframe/form/SVG 等请求或导航入口。
  const safeTags = new Set(['p','div','span','strong','b','em','i','u','br','hr','table','thead','tbody','tr','td','th','ul','ol','li','h1','h2','h3','h4']);
  const safeHtml = (html.match(/<[^>]*>|[^<]+|</g) || []).map(part => {
    if (!part.startsWith('<')) return part;
    const tag = /^<\s*(\/?)\s*([a-z0-9]+)(?:\s[^>]*)?\s*\/?>$/i.exec(part);
    return tag && safeTags.has(tag[2].toLowerCase()) ? `<${tag[1]}${tag[2].toLowerCase()}>` : '';
  }).join('');
  // sandbox 无 allow-scripts/allow-same-origin，CSP 在任何模板字节之前，禁止外部资源与表单。
  return '<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; script-src &#39;none&#39;; connect-src &#39;none&#39;; img-src &#39;none&#39;; font-src &#39;none&#39;; frame-src &#39;none&#39;; form-action &#39;none&#39;; base-uri &#39;none&#39;"></head><body>' + safeHtml + '</body></html>';
}
