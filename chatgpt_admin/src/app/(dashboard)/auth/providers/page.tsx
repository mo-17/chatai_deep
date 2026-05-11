'use client';

import { useState, useEffect } from 'react';
import {
  Table, TableHeader, TableColumn, TableBody, TableRow, TableCell,
  Button, Chip, Switch, Tooltip, Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
  Input,
} from '@nextui-org/react';
import { Wrench, Pencil, Trash2, Plus } from 'lucide-react';
import { fetchProviders, createProvider, updateProvider, deleteProvider, activateProvider, testProvider } from '@/lib/api/auth-admin';
import type { SmtpProvider } from '@/lib/api/auth-admin';

export default function AuthProvidersPage() {
  const [providers, setProviders] = useState<SmtpProvider[]>([]);
  const [loading, setLoading] = useState(true);
  const [testId, setTestId] = useState<number | null>(null);
  const [testMsg, setTestMsg] = useState('');
  const [deleteId, setDeleteId] = useState<number | null>(null);
  const [editItem, setEditItem] = useState<Partial<SmtpProvider> | null>(null);
  const [newItem, setNewItem] = useState(false);
  const [form, setForm] = useState<Partial<SmtpProvider> & { password?: string }>({});

  const [refreshKey, setRefreshKey] = useState(0);
  const reload = () => { setLoading(true); setRefreshKey(k => k + 1); };

  useEffect(() => {
    fetchProviders()
      .then(setProviders)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [refreshKey]);

  const handleSave = async () => {
    if (!form.host || !form.username) return;
    try {
      if (editItem?.id) {
        await updateProvider(editItem.id, form);
      } else {
        await createProvider(form);
      }
      setEditItem(null); setNewItem(false); setForm({});
      reload();
    } catch (e) { alert(e instanceof Error ? e.message : String(e)); }
  };

  const handleDelete = async () => {
    if (!deleteId) return;
    await deleteProvider(deleteId);
    setDeleteId(null); reload();
  };

  const handleTest = async (id: number) => {
    setTestId(id); setTestMsg('');
    try {
      const r = await testProvider(id);
      setTestMsg(r.lastTestStatus === 'success' ? '✓ 测试成功' : `✗ ${r.lastTestStatus || '失败'}`);
    } catch (e) { setTestMsg(`✗ ${e instanceof Error ? e.message : String(e)}`); }
    setTestId(null);
  };

  const handleActivate = async (key: string) => {
    await activateProvider(key);
    reload();
  };

  const openEdit = (p: SmtpProvider) => {
    setEditItem(p);
    setForm({ key: p.key, host: p.host, port: p.port, secure: p.secure, username: p.username, fromName: p.fromName, fromAddress: p.fromAddress });
  };

  const openNew = () => {
    setNewItem(true);
    setForm({ key: 'generic', host: '', port: 587, secure: false, username: '', fromName: '', fromAddress: '' });
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-xl font-bold">SMTP 服务商管理</h1>
        <Button color="primary" onPress={openNew} startContent={<Plus size={16} />}>新增</Button>
      </div>
      {testMsg && <div className={`p-3 rounded text-sm ${testMsg.startsWith('✓') ? 'bg-success-50 text-success-700' : 'bg-danger-50 text-danger-700'}`}>{testMsg}</div>}
      <Table aria-label="SMTP 服务商">
        <TableHeader>
          <TableColumn>标识</TableColumn>
          <TableColumn>主机:端口</TableColumn>
          <TableColumn>发件人</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>上次测试</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody isLoading={loading} items={providers} emptyContent="暂无 SMTP 服务商">
          {(p) => (
            <TableRow key={p.id}>
              <TableCell><Chip size="sm" variant="flat" color={p.enabled ? 'success' : 'default'}>{p.key}</Chip></TableCell>
              <TableCell className="text-sm">{p.host}:{p.port} {p.secure ? '(SSL)' : ''}</TableCell>
              <TableCell className="text-sm">{p.fromName} &lt;{p.fromAddress}&gt;</TableCell>
              <TableCell>
                <Switch size="sm" isSelected={p.enabled} onValueChange={() => handleActivate(p.key)} />
              </TableCell>
              <TableCell className="text-xs text-default-500">{p.lastTestedAt ? new Date(p.lastTestedAt).toLocaleString() : '-'}</TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Tooltip content="测试"><Button size="sm" variant="flat" isIconOnly isLoading={testId === p.id} onPress={() => handleTest(p.id)}><Wrench size={14} /></Button></Tooltip>
                  <Tooltip content="编辑"><Button size="sm" variant="flat" isIconOnly onPress={() => openEdit(p)}><Pencil size={14} /></Button></Tooltip>
                  <Tooltip content="删除"><Button size="sm" variant="flat" color="danger" isIconOnly onPress={() => setDeleteId(p.id)}><Trash2 size={14} /></Button></Tooltip>
                </div>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      {/* Form Modal */}
      <Modal isOpen={editItem !== null || newItem} onClose={() => { setEditItem(null); setNewItem(false); }}>
        <ModalContent>
          <ModalHeader>{editItem ? '编辑 SMTP 服务商' : '新增 SMTP 服务商'}</ModalHeader>
          <ModalBody className="flex flex-col gap-3">
            <Input label="标识 key" value={form.key || ''} onChange={e => setForm({...form, key: e.target.value})} />
            <Input label="主机 host" value={form.host || ''} onChange={e => setForm({...form, host: e.target.value})} />
            <Input label="端口" type="number" value={String(form.port || '')} onChange={e => setForm({...form, port: Number(e.target.value)})} />
            <Switch isSelected={form.secure} onValueChange={v => setForm({...form, secure: v})}>SSL/TLS</Switch>
            <Input label="用户名" value={form.username || ''} onChange={e => setForm({...form, username: e.target.value})} />
            <Input label="密码" type="password" value={form.password || ''} onChange={e => setForm({...form, password: e.target.value})} placeholder="留空不修改" />
            <Input label="发件人名称" value={form.fromName || ''} onChange={e => setForm({...form, fromName: e.target.value})} />
            <Input label="发件人地址" value={form.fromAddress || ''} onChange={e => setForm({...form, fromAddress: e.target.value})} />
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => { setEditItem(null); setNewItem(false); }}>取消</Button>
            <Button color="primary" onPress={handleSave}>保存</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      {/* Delete Confirm */}
      <Modal isOpen={deleteId !== null} onClose={() => setDeleteId(null)}>
        <ModalContent>
          <ModalHeader>确认删除</ModalHeader>
          <ModalBody><p>此操作不可撤销，确认删除？</p></ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setDeleteId(null)}>取消</Button>
            <Button color="danger" onPress={handleDelete}>删除</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
