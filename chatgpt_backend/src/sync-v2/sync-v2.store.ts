import { Injectable } from '@nestjs/common';
import { DataSource, EntityManager, MoreThan, Repository } from 'typeorm';
import { SyncV2EventEntity } from './sync-v2-event.entity';
import { SyncV2HeadEntity } from './sync-v2-head.entity';
import { SyncV2ReceiptEntity } from './sync-v2-receipt.entity';

export const SYNC_V2_STORE = Symbol('SYNC_V2_STORE');

export type SyncV2EventWrite = Omit<
  SyncV2EventEntity,
  'sequence' | 'serverCreatedAt'
>;

export type SyncV2HeadWrite = Omit<SyncV2HeadEntity, 'id' | 'updatedAt'>;

export type SyncV2ReceiptWrite = Omit<SyncV2ReceiptEntity, 'id' | 'createdAt'>;

export interface SyncV2Transaction {
  lock(keys: string[]): Promise<void>;
  findReceipt(
    userId: number,
    changeId: string,
  ): Promise<SyncV2ReceiptEntity | null>;
  findHead(
    userId: number,
    entity: string,
    syncId: string,
  ): Promise<SyncV2HeadEntity | null>;
  findEvent(
    userId: number,
    sequence: string,
  ): Promise<SyncV2EventEntity | null>;
  appendEvent(write: SyncV2EventWrite): Promise<SyncV2EventEntity>;
  saveHead(write: SyncV2HeadWrite): Promise<SyncV2HeadEntity>;
  saveReceipt(write: SyncV2ReceiptWrite): Promise<SyncV2ReceiptEntity>;
}

export interface SyncV2Store {
  transaction<T>(
    action: (transaction: SyncV2Transaction) => Promise<T>,
  ): Promise<T>;
  pullEvents(
    userId: number,
    cursor: string,
    limit: number,
  ): Promise<SyncV2EventEntity[]>;
}

class TypeOrmSyncV2Transaction implements SyncV2Transaction {
  private readonly eventRepo: Repository<SyncV2EventEntity>;
  private readonly headRepo: Repository<SyncV2HeadEntity>;
  private readonly receiptRepo: Repository<SyncV2ReceiptEntity>;

  constructor(private readonly manager: EntityManager) {
    this.eventRepo = manager.getRepository(SyncV2EventEntity);
    this.headRepo = manager.getRepository(SyncV2HeadEntity);
    this.receiptRepo = manager.getRepository(SyncV2ReceiptEntity);
  }

  async lock(keys: string[]): Promise<void> {
    const sorted = [...new Set(keys)].sort();
    if (sorted.length === 0) return;
    await this.manager.query(
      `SELECT pg_advisory_xact_lock(hashtextextended(lock_key, 0))
       FROM (
         SELECT unnest($1::text[]) AS lock_key
         ORDER BY lock_key
       ) AS ordered_locks`,
      [sorted],
    );
  }

  findReceipt(userId: number, changeId: string) {
    return this.receiptRepo.findOne({ where: { userId, changeId } });
  }

  findHead(userId: number, entity: string, syncId: string) {
    return this.headRepo.findOne({ where: { userId, entity, syncId } });
  }

  findEvent(userId: number, sequence: string) {
    return this.eventRepo.findOne({ where: { userId, sequence } });
  }

  async appendEvent(write: SyncV2EventWrite) {
    return this.eventRepo.save(this.eventRepo.create(write));
  }

  async saveHead(write: SyncV2HeadWrite) {
    const existing = await this.findHead(
      write.userId,
      write.entity,
      write.syncId,
    );
    if (existing) {
      this.headRepo.merge(existing, write);
      return this.headRepo.save(existing);
    }
    return this.headRepo.save(this.headRepo.create(write));
  }

  async saveReceipt(write: SyncV2ReceiptWrite) {
    return this.receiptRepo.save(this.receiptRepo.create(write));
  }
}

@Injectable()
export class TypeOrmSyncV2Store implements SyncV2Store {
  constructor(private readonly dataSource: DataSource) {}

  transaction<T>(
    action: (transaction: SyncV2Transaction) => Promise<T>,
  ): Promise<T> {
    return this.dataSource.transaction((manager) =>
      action(new TypeOrmSyncV2Transaction(manager)),
    );
  }

  pullEvents(userId: number, cursor: string, limit: number) {
    return this.dataSource.getRepository(SyncV2EventEntity).find({
      where: { userId, sequence: MoreThan(cursor) },
      order: { sequence: 'ASC' },
      take: limit,
    });
  }
}
