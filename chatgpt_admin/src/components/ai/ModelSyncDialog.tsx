'use client';

import { useEffect, useRef, useState } from 'react';
import {
  Button,
  Modal,
  ModalBody,
  ModalContent,
  ModalFooter,
  ModalHeader,
} from '@heroui/react';
import { modelSyncApi } from '@/lib/api/model-sync';
import {
  captureAuthSession,
  isAuthSessionCurrent,
  type AuthSession,
} from '@/lib/api/auth-session';
import type { AiProvider } from '@/types/ai';
import type { ModelSyncPreview, ModelSyncRow } from '@/types/model-sync';

const SAFE_MESSAGES = new Set([
  '模型目录获取失败，请检查服务商配置后重新预览',
  '服务商未配置有效密钥或安全目录地址',
  '模型同步参数无效',
  '预览已过期或不属于当前会话，请重新预览',
  '服务商配置已变化，请重新预览',
  '模型预览正在进行，请稍后再试',
  '模型目录超出安全限制，未生成预览',
  '导入结果未确认，请刷新模型列表核对后重新预览',
]);
const safeError = (error: unknown) =>
  error instanceof Error && SAFE_MESSAGES.has(error.message)
    ? error.message
    : '操作结果未确认，请刷新模型列表核对，再重新预览';
const bit = (value?: boolean) =>
  value === undefined ? '未知' : value ? '支持' : '不支持';
const FIELDS: Record<string, string> = {
  displayName: '名称',
  description: '描述',
  supportsVision: '视觉',
  supportsTool: '工具',
  supportsReasoning: '推理',
  supportsPdf: 'PDF',
};
export function ModelSyncDialog({
  provider,
  onClose,
  onRefresh,
}: {
  provider: AiProvider;
  onClose: () => void;
  onRefresh: () => void;
}) {
  const [originalScope] = useState<{
    session: AuthSession;
    providerId: number;
  } | null>(() => {
    try {
      return { session: captureAuthSession(), providerId: provider.id };
    } catch {
      return null;
    }
  });
  const [preview, setPreview] = useState<ModelSyncPreview | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState<'preview' | 'import' | null>(null);
  const [message, setMessage] = useState(
    originalScope ? '' : '会话已变化，请关闭后重新打开',
  );
  const scope = useRef(originalScope);
  const generation = useRef(0);
  const mounted = useRef(false);
  const pending = useRef(false);
  useEffect(() => {
    mounted.current = true;
    scope.current = originalScope;
    return () => {
      mounted.current = false;
      scope.current = null;
    };
  }, [originalScope]);
  function current(version: number) {
    return (
      mounted.current &&
      generation.current === version &&
      scope.current?.providerId === provider.id &&
      isAuthSessionCurrent(scope.current.session)
    );
  }
  async function discover() {
    if (pending.current) return;
    const version = ++generation.current;
    if (!current(version)) {
      if (mounted.current) setMessage('会话已变化，请关闭后重新打开');
      return;
    }
    const original = scope.current!;
    pending.current = true;
    setBusy('preview');
    setMessage('');
    setPreview(null);
    setSelected(new Set());
    try {
      const result = await modelSyncApi.preview(
        original.providerId,
        original.session,
      );
      if (!current(version)) return;
      if (
        result.providerId !== original.providerId ||
        result.providerCode !== provider.code
      ) {
        setMessage('服务商配置已变化，请关闭后重新打开');
        return;
      }
      setPreview(result);
    } catch (error) {
      if (current(version)) setMessage(safeError(error));
    } finally {
      if (generation.current === version) pending.current = false;
      if (current(version)) setBusy(null);
    }
  }
  async function confirm() {
    if (pending.current) return;
    const version = ++generation.current;
    if (!current(version)) {
      if (mounted.current) setMessage('会话已变化，请关闭后重新打开');
      return;
    }
    if (!preview || !selected.size) return;
    const original = scope.current!;
    if (preview.expiresAt <= Date.now()) {
      setPreview(null);
      setMessage('预览已过期或不属于当前会话，请重新预览');
      return;
    }
    pending.current = true;
    setBusy('import');
    setMessage('');
    try {
      const result = await modelSyncApi.import(
        original.providerId,
        preview.previewId,
        [...selected],
        original.session,
      );
      if (!current(version)) return;
      setPreview(null);
      setSelected(new Set());
      setMessage(
        `已新增 ${result.imported.length} 个停用模型，跳过 ${result.skipped.length} 个已存在模型`,
      );
      onRefresh();
    } catch (error) {
      if (current(version)) {
        setPreview(null);
        setSelected(new Set());
        setMessage(safeError(error));
      }
    } finally {
      if (generation.current === version) pending.current = false;
      if (current(version)) setBusy(null);
    }
  }
  function toggle(row: ModelSyncRow, checked: boolean) {
    if (busy || row.status !== 'new') return;
    setSelected((old) => {
      const next = new Set(old);
      if (checked) next.add(row.modelId);
      else next.delete(row.modelId);
      return next;
    });
  }
  return (
    <Modal
      isOpen
      onClose={onClose}
      size="5xl"
      scrollBehavior="inside"
      isDismissable={!busy}
    >
      <ModalContent>
        <ModalHeader>
          同步模型 · {provider.displayName}（{provider.code}）
        </ModalHeader>
        <ModalBody>
          <p className="text-sm text-default-500">
            先读取服务商目录，再明确选择新增项。已有模型、手工名称、价格、能力、默认值和目录中消失的旧模型全部保留；新增模型停用且不设默认。价格和未提供的能力不作推测。
          </p>
          <p className="text-sm text-default-500">
            新模型启用前请在编辑页核对能力。目录信息不代表实际模型调用已通过。仅支持
            HTTPS 公共目录地址，预览有效期五分钟。
          </p>
          <div className="flex gap-2">
            <Button
              onPress={discover}
              isLoading={busy === 'preview'}
              isDisabled={!!busy}
            >
              获取目录预览
            </Button>
            <Button
              variant="flat"
              onPress={() => {
                if (current(generation.current)) onRefresh();
              }}
              isDisabled={!!busy}
            >
              刷新列表核对
            </Button>
          </div>
          {message && <p role="status">{message}</p>}
          {preview && (
            <>
              <p>
                新增 {preview.rows.filter((r) => r.status === 'new').length} ·
                已有{' '}
                {preview.rows.filter((r) => r.status === 'existing').length} ·
                信息有变化{' '}
                {preview.rows.filter((r) => r.status === 'changed').length}
                （保留手工配置）
              </p>
              {preview.rows.length === 0 && (
                <p>服务商返回空目录，未删除任何已有模型。</p>
              )}
              <div className="overflow-x-auto">
                <table className="w-full text-sm" aria-label="模型同步预览">
                  <thead>
                    <tr>
                      <th>选择</th>
                      <th>模型</th>
                      <th>状态</th>
                      <th>官方目录元数据</th>
                    </tr>
                  </thead>
                  <tbody>
                    {preview.rows.map((row) => (
                      <tr key={row.modelId}>
                        <td>
                          <input
                            type="checkbox"
                            aria-label={`新增 ${row.modelId}`}
                            checked={selected.has(row.modelId)}
                            disabled={row.status !== 'new' || !!busy}
                            onChange={(e) => toggle(row, e.target.checked)}
                          />
                        </td>
                        <td className="break-all p-2">
                          <div>{row.displayName}</div>
                          <div>
                            {provider.code} · {row.modelId}
                          </div>
                          {row.description && <div>{row.description}</div>}
                        </td>
                        <td>
                          {row.status === 'new'
                            ? '新增（停用）'
                            : row.status === 'changed'
                              ? `有变化，保留现值：${row.changes.map((k) => FIELDS[k] || '元数据').join('、')}`
                              : '已有，保留'}
                        </td>
                        <td className="p-2">
                          视觉：{bit(row.supportsVision)}；工具：
                          {bit(row.supportsTool)}；推理：
                          {bit(row.supportsReasoning)}；PDF：
                          {bit(row.supportsPdf)}
                          <br />
                          上下文：{row.contextWindow ?? '未知'}；输出上限：
                          {row.maxOutputTokens ?? '未知'}；价格：未知
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </ModalBody>
        <ModalFooter>
          <Button variant="flat" onPress={onClose}>
            关闭
          </Button>
          <Button
            color="primary"
            isLoading={busy === 'import'}
            isDisabled={!!busy || !preview || !selected.size}
            onPress={confirm}
          >
            确认导入所选新增模型（{selected.size}）
          </Button>
        </ModalFooter>
      </ModalContent>
    </Modal>
  );
}
