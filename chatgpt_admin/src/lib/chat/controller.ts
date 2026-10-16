import {
  chatApi,
  type ChatMessage,
  type ConversationRecord,
} from '@/lib/api/chat';
import type { Conversation } from '@/components/ai-chat/chat-sidebar';
import { ChatFailure, safeChatFailure } from './errors';
import {
  captureChatScope,
  chatScopeCurrent,
  chatContextSignature,
  chatScopeKey,
  type ChatScope,
} from './scope';
import {
  choicesFromMetadata,
  pairFromKey,
  pairKey,
  readPair,
  readPreference,
  selectionLabel,
  writePreference,
  type ChatChoice,
  type ChatPair,
  type ChatSelection,
} from './selection';

interface Entry {
  id: string;
  backendId?: number;
  title: string;
  updatedAt: number;
  selection: ChatSelection;
  messages: ChatMessage[];
  loaded: boolean;
  createAttempted?: boolean;
  createUnknown?: boolean;
  saveUnknown?: boolean;
  selectionUnknown?: boolean;
}
interface Run {
  entry: Entry;
  life: number;
  generation: number;
  settled: boolean;
  dispatched: boolean;
  content: string;
  assistant: string;
  history: ChatMessage[];
  pair?: ChatPair;
  abort?: AbortController;
}
export interface ChatSnapshot {
  conversations: Conversation[];
  activeId: string | null;
  messages: ChatMessage[];
  isLoading: boolean;
  error: string | null;
  selection: ChatSelection;
  selectionKey: string;
  selectionLabel: string;
  choices: ChatChoice[];
  metadataStatus: 'loading' | 'ready' | 'failed';
  metadataError: string | null;
  canSend: boolean;
  contextKey: string;
}
// 生命周期与网络结算独立于 React updater；一次用户动作只结算一次。
export class ChatController {
  readonly scope: ChatScope | null;
  private mounted = false;
  private life = 0;
  private generation = 0;
  private listVersion = 0;
  private metadataVersion = 0;
  private entryCounter = 0;
  private entries = new Map<string, Entry>();
  private activeId: string | null = null;
  private run?: Run;
  private mutation = false;
  private pendingSelections = new Set<Entry>();
  private error: string | null = null;
  private preference: ChatSelection = { kind: 'none' };
  private globalPair?: ChatPair;
  private choices: ChatChoice[] = [];
  private metadataStatus: ChatSnapshot['metadataStatus'] = 'loading';
  private metadataError: string | null = null;
  private listeners = new Set<() => void>();
  private snapshot: ChatSnapshot;
  constructor(expectedSignature: string) {
    try {
      if (expectedSignature !== chatContextSignature())
        throw new ChatFailure('scope_changed');
      this.scope = captureChatScope();
      this.preference = readPreference(this.scope);
    } catch {
      this.scope = null;
      this.error = new ChatFailure('ownership_unverified').message;
    }
    this.snapshot = this.buildSnapshot();
  }
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  getSnapshot = () => this.snapshot;
  private valid(life = this.life) {
    return (
      this.mounted &&
      life === this.life &&
      this.scope !== null &&
      chatScopeCurrent(this.scope)
    );
  }
  private current(run: Run) {
    return (
      this.valid(run.life) &&
      run.generation === this.generation &&
      run.entry.id === this.activeId &&
      this.run === run &&
      !run.settled
    );
  }
  private check(run: Run) {
    if (!this.current(run)) throw new ChatFailure('scope_changed');
  }
  private initialSelection(): ChatSelection {
    if (this.preference.kind !== 'none') return this.preference;
    return this.globalPair
      ? { kind: 'pair', pair: this.globalPair }
      : { kind: 'none' };
  }
  private buildSnapshot(): ChatSnapshot {
    const entry = this.activeId ? this.entries.get(this.activeId) : undefined;
    const selection = entry?.selection ?? this.initialSelection();
    const known =
      selection.kind === 'pair' &&
      this.choices.some((c) => c.key === pairKey(selection.pair));
    return {
      conversations: Array.from(this.entries.values(), (e) => ({
        id: e.id,
        title: e.title,
        updatedAt: e.updatedAt,
      })),
      activeId: this.activeId,
      messages: entry?.messages ?? [],
      isLoading: !!this.run || this.mutation,
      error: this.error,
      selection,
      selectionKey: selection.kind === 'pair' ? pairKey(selection.pair) : '',
      selectionLabel: selectionLabel(selection, this.choices),
      choices: this.choices,
      metadataStatus: this.metadataStatus,
      metadataError: this.metadataError,
      canSend:
        !!this.scope &&
        !this.run &&
        !this.mutation &&
        !entry?.createUnknown &&
        !entry?.saveUnknown &&
        !entry?.selectionUnknown &&
        (!entry || entry.loaded) &&
        (known || selection.kind === 'legacy'),
      contextKey: this.scope
        ? JSON.stringify([chatScopeKey(this.scope), this.scope.session.epoch])
        : 'unavailable',
    };
  }
  private publish() {
    this.snapshot = this.buildSnapshot();
    for (const listener of this.listeners) listener();
  }
  activate = () => {
    this.mounted = true;
    this.life++;
    this.publish();
    void this.refreshConversations();
    void this.refreshMetadata();
    return () => {
      this.mounted = false;
      this.life++;
      this.generation++;
      const run = this.run;
      this.run = undefined;
      if (run) {
        if (run.dispatched) {
          run.entry.saveUnknown = true;
          this.error = new ChatFailure('save_unknown').message;
        } else if (run.entry.createAttempted && !run.entry.backendId) {
          run.entry.createUnknown = true;
          this.error = new ChatFailure('create_unknown').message;
        }
        run.settled = true;
        run.abort?.abort();
      }
    };
  };
  refreshMetadata = async () => {
    const life = this.life,
      version = ++this.metadataVersion;
    if (!this.valid() || !this.scope) return;
    this.metadataStatus = 'loading';
    this.metadataError = null;
    this.publish();
    try {
      const data = await chatApi.metadata(this.scope);
      if (!this.valid(life) || version !== this.metadataVersion) return;
      const choices = choicesFromMetadata(data.providers, data.models);
      this.choices = choices;
      this.globalPair = undefined;
      try {
        const pair = readPair({
          providerCode: data.config.defaultProviderCode,
          modelId: data.config.defaultModelId,
        });
        if (choices.some((c) => c.key === pairKey(pair)))
          this.globalPair = pair;
      } catch {
        /* no implicit replacement */
      }
      // global 只给从未选择的新草稿；既有会话/个人失效引用不改写。
      for (const entry of this.entries.values())
        if (
          !entry.backendId &&
          !entry.createAttempted &&
          entry.selection.kind === 'none' &&
          this.globalPair
        )
          entry.selection = { kind: 'pair', pair: this.globalPair };
      if (!this.globalPair && this.preference.kind === 'none')
        this.metadataError =
          '全局默认已删除、停用或不完整，请明确选择服务商和模型';
      this.metadataStatus = 'ready';
    } catch (error) {
      if (!this.valid(life) || version !== this.metadataVersion) return;
      this.metadataStatus = 'failed';
      this.metadataError = safeChatFailure(error).message;
    }
    this.publish();
  };
  refreshConversations = async () => {
    const life = this.life,
      version = ++this.listVersion;
    if (!this.valid() || !this.scope) return;
    try {
      const list = await chatApi.listConversations(this.scope);
      if (!this.valid(life) || version !== this.listVersion) return;
      const ids = new Set<string>();
      for (const row of list) {
        const id = String(row.id);
        ids.add(id);
        const existing = this.entries.get(id);
        if (
          existing &&
          (existing === this.run?.entry ||
            existing.saveUnknown ||
            this.pendingSelections.has(existing))
        )
          continue;
        this.entries.set(id, this.fromRecord(row, existing));
      }
      for (const [id, entry] of this.entries)
        if (
          entry.backendId &&
          !ids.has(id) &&
          entry !== this.run?.entry &&
          !this.pendingSelections.has(entry) &&
          !entry.saveUnknown
        )
          this.entries.delete(id);
      if (this.activeId && !this.entries.has(this.activeId)) {
        this.activeId = null;
        this.generation++;
      }
    } catch (error) {
      if (!this.valid(life) || version !== this.listVersion) return;
      this.error = safeChatFailure(error).message;
    }
    this.publish();
  };
  private fromRecord(row: ConversationRecord, existing?: Entry): Entry {
    return Object.assign(existing ?? {}, {
      id: String(row.id),
      backendId: row.id,
      title: row.title,
      updatedAt: new Date(row.updatedAt).getTime(),
      selection:
        row.providerCode === null
          ? { kind: 'legacy' as const, modelId: row.model }
          : {
              kind: 'pair' as const,
              pair: { providerCode: row.providerCode, modelId: row.model },
            },
      messages: existing?.messages ?? [],
      loaded: existing?.loaded ?? false,
      saveUnknown: existing?.saveUnknown,
      selectionUnknown: false,
    });
  }
  // 查询列表不能换掉在途操作对象；选择请求结束后再废弃其间捕获的旧列表快照。
  private async updateEntrySelection(entry: Entry, pair: ChatPair) {
    if (!this.scope || this.pendingSelections.has(entry))
      throw new ChatFailure('conversation_request_failed');
    this.pendingSelections.add(entry);
    this.listVersion++;
    entry.selectionUnknown = true;
    try {
      await chatApi.updateSelection(entry.backendId!, pair, this.scope);
    } finally {
      this.pendingSelections.delete(entry);
      this.listVersion++;
    }
  }
  newConversation = (): string => {
    if (!this.valid()) return 'unavailable';
    this.cancelRequest();
    this.generation++;
    const id = 'draft_' + ++this.entryCounter;
    this.entries.set(id, {
      id,
      title: '',
      updatedAt: Date.now(),
      selection: this.initialSelection(),
      messages: [],
      loaded: true,
    });
    this.activeId = id;
    this.error = null;
    this.publish();
    return id;
  };
  selectConversation = async (id: string) => {
    if (!this.valid() || !this.scope || !this.entries.has(id)) return;
    this.cancelRequest();
    const generation = ++this.generation,
      life = this.life,
      entry = this.entries.get(id)!;
    this.activeId = id;
    this.error = entry.saveUnknown
      ? new ChatFailure('save_unknown').message
      : entry.createUnknown
        ? new ChatFailure('create_unknown').message
        : null;
    this.publish();
    if (!entry.backendId) return;
    try {
      const messages = await chatApi.listMessages(entry.backendId, this.scope);
      if (
        !this.valid(life) ||
        generation !== this.generation ||
        this.activeId !== id
      )
        return;
      // 未确认保存不按内容比对推断提交；保留收到的输出，GET只用于核对。
      if (!entry.saveUnknown) entry.messages = messages;
      entry.loaded = true;
    } catch (error) {
      if (
        !this.valid(life) ||
        generation !== this.generation ||
        this.activeId !== id
      )
        return;
      entry.loaded = false;
      this.error = safeChatFailure(error).message;
    }
    this.publish();
  };
  chooseSelection = async (key: string) => {
    if (!this.valid() || !this.scope || this.run || this.mutation) return;
    const life = this.life,
      generation = this.generation,
      id = this.activeId;
    this.listVersion++;
    this.mutation = true;
    this.error = null;
    this.publish();
    try {
      const pair = pairFromKey(key);
      if (!this.choices.some((c) => c.key === key))
        throw new ChatFailure('model_unavailable');
      const entry = id ? this.entries.get(id) : undefined;
      if (entry?.saveUnknown || entry?.createUnknown)
        throw new ChatFailure(
          entry.saveUnknown ? 'save_unknown' : 'create_unknown',
        );
      if (entry?.backendId) {
        await this.updateEntrySelection(entry, pair);
      }
      if (
        !this.valid(life) ||
        generation !== this.generation ||
        id !== this.activeId
      )
        return;
      writePreference(this.scope, pair);
      this.preference = { kind: 'pair', pair };
      if (entry) {
        entry.selection = this.preference;
        entry.selectionUnknown = false;
      }
    } catch (error) {
      if (
        this.valid(life) &&
        generation === this.generation &&
        id === this.activeId
      )
        this.error = safeChatFailure(error).message;
    } finally {
      if (this.valid(life)) {
        this.mutation = false;
        this.publish();
      }
    }
  };
  deleteConversation = async (id: string) => {
    const life = this.life,
      generation = this.generation,
      entry = this.entries.get(id);
    if (!this.valid() || !this.scope || !entry) return;
    if (id === this.activeId) this.cancelRequest();
    try {
      if (entry.backendId)
        await chatApi.deleteConversation(entry.backendId, this.scope);
      if (!this.valid(life)) return;
      this.entries.delete(id);
      if (this.activeId === id) {
        this.activeId = null;
        this.generation++;
      }
      this.publish();
    } catch (error) {
      if (this.valid(life) && generation === this.generation) {
        this.error = safeChatFailure(error).message;
        this.publish();
      }
    }
  };
  renameConversation = async (id: string, title: string) => {
    const life = this.life,
      generation = this.generation,
      entry = this.entries.get(id);
    if (!this.valid() || !this.scope || !entry) return;
    try {
      if (entry.backendId)
        await chatApi.updateConversation(entry.backendId, title, this.scope);
      if (!this.valid(life) || this.entries.get(id) !== entry) return;
      entry.title = title;
      this.publish();
    } catch (error) {
      if (this.valid(life) && generation === this.generation) {
        this.error = safeChatFailure(error).message;
        this.publish();
      }
    }
  };
  cancelRequest = () => {
    const run = this.run;
    if (!run || run.settled) return;
    run.abort?.abort();
    void this.settle(run, new ChatFailure('cancelled'));
  };
  sendMessage = async (content: string, key?: string, targetId?: string) => {
    if (
      !content.trim() ||
      !this.valid() ||
      !this.scope ||
      this.run ||
      this.mutation
    )
      return;
    const id = targetId ?? this.activeId,
      entry = id ? this.entries.get(id) : undefined;
    if (!entry || id !== this.activeId) return;
    const run: Run = {
      entry,
      life: this.life,
      generation: this.generation,
      settled: false,
      dispatched: false,
      content,
      assistant: '',
      history: entry.messages.map((m) => ({ ...m })),
    };
    this.run = run;
    this.error = null;
    this.publish();
    try {
      if (!entry.loaded) throw new ChatFailure('ownership_unverified');
      if (entry.selectionUnknown)
        throw new ChatFailure('conversation_request_failed');
      if (entry.saveUnknown || entry.createUnknown)
        throw new ChatFailure(
          entry.saveUnknown ? 'save_unknown' : 'create_unknown',
        );
      const original = entry.selection;
      if (key && (original.kind !== 'pair' || key !== pairKey(original.pair)))
        throw new ChatFailure('selection_required');
      let pair: ChatPair;
      if (original.kind === 'legacy') {
        pair = await chatApi.resolveSelection(original.modelId, this.scope);
        this.check(run);
        await this.updateEntrySelection(entry, pair);
        this.check(run);
        entry.selectionUnknown = false;
        entry.selection = { kind: 'pair', pair };
      } else if (original.kind === 'pair') pair = { ...original.pair };
      else throw new ChatFailure('selection_required');
      run.pair = pair;
      this.check(run);
      if (!entry.backendId) {
        if (entry.createAttempted) throw new ChatFailure('create_unknown');
        entry.createAttempted = true;
        try {
          const created = await chatApi.createConversation(pair, this.scope);
          this.check(run);
          this.entries.delete(entry.id);
          entry.id = String(created.id);
          entry.backendId = created.id;
          this.entries.set(entry.id, entry);
          this.activeId = entry.id;
        } catch (error) {
          entry.createUnknown = true;
          throw error instanceof ChatFailure &&
            error.status &&
            error.status < 500
            ? error
            : new ChatFailure('create_unknown');
        }
      }
      this.check(run);
      if (!entry.title) {
        const title = content.slice(0, 30);
        await chatApi.updateConversation(entry.backendId!, title, this.scope);
        this.check(run);
        entry.title = title;
      }
      entry.updatedAt = Date.now();
      entry.messages = [
        ...run.history,
        { role: 'user', content },
        { role: 'assistant', content: '' },
      ];
      run.dispatched = true;
      this.publish();
      run.abort = chatApi.streamComplete(
        {
          model: pair.modelId,
          providerCode: pair.providerCode,
          messages: [...run.history, { role: 'user', content }],
          max_tokens: 2000,
        },
        (token) => {
          if (!this.current(run)) return;
          run.assistant += token;
          entry.messages = [
            ...run.history,
            { role: 'user', content },
            { role: 'assistant', content: run.assistant },
          ];
          this.publish();
        },
        () => {
          void this.settle(run);
        },
        (error) => {
          void this.settle(run, error);
        },
        this.scope,
      );
    } catch (error) {
      await this.settle(run, safeChatFailure(error));
    }
  };
  private async settle(run: Run, error?: ChatFailure) {
    if (run.settled) return;
    run.settled = true;
    const wasCurrent =
      this.run === run &&
      run.generation === this.generation &&
      run.entry.id === this.activeId;
    if (this.valid(run.life) && wasCurrent) {
      this.error = error?.message ?? null;
      this.publish();
    }
    if (
      run.dispatched &&
      run.entry.backendId &&
      this.valid(run.life) &&
      this.scope
    ) {
      const increment: ChatMessage[] = [
        { role: 'user', content: run.content },
        ...(run.assistant
          ? [{ role: 'assistant' as const, content: run.assistant }]
          : []),
      ];
      run.entry.messages = [...run.history, ...increment];
      try {
        await chatApi.saveMessages(run.entry.backendId, increment, this.scope);
      } catch {
        run.entry.saveUnknown = true;
        if (
          this.valid(run.life) &&
          wasCurrent &&
          run.generation === this.generation &&
          this.activeId === run.entry.id
        )
          this.error = new ChatFailure('save_unknown').message;
      }
    }
    if (this.run === run) this.run = undefined;
    if (this.valid(run.life)) this.publish();
  }
}
