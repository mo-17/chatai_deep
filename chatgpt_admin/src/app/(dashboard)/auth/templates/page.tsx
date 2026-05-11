'use client';

import { useState, useEffect } from 'react';
import { Table, TableHeader, TableColumn, TableBody, TableRow, TableCell, Button, Modal, ModalContent, ModalHeader, ModalBody, ModalFooter, Input, Textarea } from '@heroui/react';
import { Pencil } from 'lucide-react';
import { fetchTemplates, updateTemplate } from '@/lib/api/auth-admin';
import type { EmailTemplate } from '@/lib/api/auth-admin';

export default function AuthTemplatesPage() {
  const [templates, setTemplates] = useState<EmailTemplate[]>([]);
  const [loading, setLoading] = useState(true);
  const [editItem, setEditItem] = useState<EmailTemplate | null>(null);

  const [refreshKey, setRefreshKey] = useState(0);
  const reload = () => { setLoading(true); setRefreshKey(k => k + 1); };

  useEffect(() => {
    fetchTemplates()
      .then(setTemplates)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [refreshKey]);

  const handleSave = async () => {
    if (!editItem) return;
    try {
      await updateTemplate(editItem.id, { subject: editItem.subject, html: editItem.html });
      setEditItem(null); reload();
    } catch (e) { alert(e instanceof Error ? e.message : String(e)); }
  };

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">邮件模板</h1>
      <Table aria-label="邮件模板">
        <TableHeader>
          <TableColumn>代码</TableColumn>
          <TableColumn>名称</TableColumn>
          <TableColumn>主题</TableColumn>
          <TableColumn>更新时间</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody isLoading={loading} items={templates} emptyContent="暂无模板">
          {(t) => (
            <TableRow key={t.id}>
              <TableCell><code className="text-xs bg-default-100 px-1 rounded">{t.code}</code></TableCell>
              <TableCell>{t.name}</TableCell>
              <TableCell className="text-sm">{t.subject}</TableCell>
              <TableCell className="text-xs text-default-500">{new Date(t.updatedAt).toLocaleString()}</TableCell>
              <TableCell>
                <Button size="sm" variant="flat" isIconOnly onPress={() => setEditItem(t)}><Pencil size={14} /></Button>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      {/* Edit Modal */}
      <Modal isOpen={editItem !== null} onClose={() => setEditItem(null)} size="2xl">
        <ModalContent>
          <ModalHeader>编辑模板: {editItem?.name}</ModalHeader>
          <ModalBody className="flex flex-col gap-3">
            <Input label="主题" value={editItem?.subject || ''} onChange={e => setEditItem(prev => prev ? { ...prev, subject: e.target.value } : null)} />
            <Textarea label="HTML" value={editItem?.html || ''} onChange={e => setEditItem(prev => prev ? { ...prev, html: e.target.value } : null)} minRows={10} />
            {editItem?.html && (
              <div className="border rounded p-3 bg-default-50">
                <p className="text-xs text-default-500 mb-1">预览</p>
                <div dangerouslySetInnerHTML={{ __html: editItem.html.replace('{{code}}', '123456') }} />
              </div>
            )}
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setEditItem(null)}>取消</Button>
            <Button color="primary" onPress={handleSave}>保存</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
