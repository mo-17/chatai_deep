import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, Between, FindOptionsWhere } from 'typeorm';
import { Usage } from '../chat/usage.entity';
import { User } from '../user/user.entity';
import { toInt } from '../util/num';

@Injectable()
export class AdminUsageService {
  constructor(
    @InjectRepository(Usage)
    private usageRepo: Repository<Usage>,
  ) {}

  async list(query: {
    userId?: string;
    provider?: string;
    model?: string;
    from?: string;
    to?: string;
    page?: number;
    pageSize?: number;
  }) {
    const page = query.page || 1;
    const pageSize = query.pageSize || 10;
    const where: FindOptionsWhere<Usage> = {};

    if (query.userId) {
      where.userId = parseInt(query.userId, 10);
    }
    if (query.provider) {
      where.provider = query.provider;
    }
    if (query.model) {
      where.model = query.model;
    }
    if (query.from || query.to) {
      const from = query.from ? new Date(query.from) : new Date('2000-01-01');
      const to = query.to ? new Date(query.to + 'T23:59:59.999Z') : new Date();
      where.createdAt = Between(from, to);
    }

    const [rawList, total] = await this.usageRepo.findAndCount({
      where,
      order: { createdAt: 'DESC' },
      take: pageSize,
      skip: (page - 1) * pageSize,
    });

    // Join user names
    const userIds = [...new Set(rawList.map((u) => u.userId))];
    const users = userIds.length
      ? await this.usageRepo.manager.find(User, {
          where: userIds.map((id) => ({ id })),
          select: ['id', 'userName'],
        })
      : [];

    const userMap = new Map(users.map((u) => [u.id, u.userName]));
    const list = rawList.map((r) => ({
      id: r.id,
      userId: r.userId,
      userName: userMap.get(r.userId) || '未知',
      provider: r.provider,
      model: r.model,
      promptTokens: r.promptTokens,
      completionTokens: r.completionTokens,
      totalTokens: r.totalTokens,
      createdAt: r.createdAt,
    }));

    return { list, total, page, pageSize };
  }

  async summary() {
    const now = new Date();
    const todayStart = new Date(
      now.getFullYear(),
      now.getMonth(),
      now.getDate(),
    );
    const weekStart = new Date(todayStart);
    weekStart.setDate(weekStart.getDate() - weekStart.getDay());
    const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);

    const [
      todayResult,
      weekResult,
      monthResult,
      allResult,
      userCount,
      activeToday,
    ] = await Promise.all([
      this.aggregateSince(todayStart),
      this.aggregateSince(weekStart),
      this.aggregateSince(monthStart),
      this.aggregateSince(new Date('2000-01-01')),
      this.usageRepo.manager.count(User),
      this.usageRepo
        .createQueryBuilder('usage')
        .select('COUNT(DISTINCT "userId")', 'cnt')
        .where('usage.createdAt >= :start', { start: todayStart })
        .getRawOne<{ cnt: string | number }>()
        .then((r) => toInt(r?.cnt)),
    ]);

    return {
      today: todayResult,
      week: weekResult,
      month: monthResult,
      all: allResult,
      userCount,
      activeToday,
    };
  }

  private async aggregateSince(since: Date) {
    const result = await this.usageRepo
      .createQueryBuilder('usage')
      .select('COALESCE(SUM("totalTokens"), 0)', 'tokens')
      .addSelect('COUNT(*)', 'calls')
      .where('usage.createdAt >= :start', { start: since })
      .getRawOne<{ tokens: string; calls: string }>();
    return {
      tokens: toInt(result?.tokens),
      calls: toInt(result?.calls),
    };
  }

  async series(from?: string, to?: string) {
    const toDate = to ? new Date(to + 'T23:59:59.999Z') : new Date();
    const fromDate = from
      ? new Date(from)
      : new Date(toDate.getTime() - 30 * 24 * 3600 * 1000);

    const rows = await this.usageRepo
      .createQueryBuilder('usage')
      .select('DATE("createdAt")', 'date')
      .addSelect('COALESCE(SUM("totalTokens"), 0)', 'tokens')
      .addSelect('COUNT(*)', 'calls')
      .where('usage.createdAt >= :from', { from: fromDate })
      .andWhere('usage.createdAt <= :to', { to: toDate })
      .groupBy('DATE("createdAt")')
      .orderBy('date', 'ASC')
      .getRawMany<{ date: string; tokens: string; calls: string }>();

    // Fill missing dates with zero
    const dateMap = new Map(
      rows.map((r) => [
        r.date,
        { tokens: toInt(r.tokens), calls: toInt(r.calls) },
      ]),
    );
    const list: Array<{ date: string; tokens: number; calls: number }> = [];
    const current = new Date(fromDate);
    while (current <= toDate) {
      const key = current.toISOString().slice(0, 10);
      list.push({
        date: key,
        tokens: dateMap.get(key)?.tokens || 0,
        calls: dateMap.get(key)?.calls || 0,
      });
      current.setDate(current.getDate() + 1);
    }

    return { list };
  }

  async byProvider() {
    const rows = await this.usageRepo
      .createQueryBuilder('usage')
      .select('provider')
      .addSelect('COALESCE(SUM("totalTokens"), 0)', 'tokens')
      .addSelect('COUNT(*)', 'calls')
      .groupBy('provider')
      .getRawMany<{ provider: string; tokens: string; calls: string }>();

    return {
      list: rows.map((r) => ({
        provider: r.provider,
        tokens: toInt(r.tokens),
        calls: toInt(r.calls),
      })),
    };
  }

  async topUsers(limit = 10, days = 7) {
    const since = new Date();
    since.setDate(since.getDate() - days);

    const rows = await this.usageRepo
      .createQueryBuilder('usage')
      .select('usage.userId', 'userId')
      .addSelect('COALESCE(SUM("totalTokens"), 0)', 'tokens')
      .addSelect('COUNT(*)', 'calls')
      .where('usage.createdAt >= :since', { since })
      .groupBy('usage.userId')
      .orderBy('tokens', 'DESC')
      .limit(limit)
      .getRawMany<{ userId: number; tokens: string; calls: string }>();

    const userIds = rows.map((r) => r.userId);
    const users = userIds.length
      ? await this.usageRepo.manager.find(User, {
          where: userIds.map((id) => ({ id })),
          select: ['id', 'userName'],
        })
      : [];
    const userMap = new Map(users.map((u) => [u.id, u.userName]));

    return {
      list: rows.map((r) => ({
        userId: r.userId,
        userName: userMap.get(r.userId) || '未知',
        tokens: toInt(r.tokens),
        calls: toInt(r.calls),
      })),
    };
  }

  async exportCsv(query: {
    userId?: string;
    provider?: string;
    model?: string;
    from?: string;
    to?: string;
  }): Promise<string> {
    const where: FindOptionsWhere<Usage> = {};
    if (query.userId) where.userId = parseInt(query.userId, 10);
    if (query.provider) where.provider = query.provider;
    if (query.model) where.model = query.model;
    if (query.from || query.to) {
      const from = query.from ? new Date(query.from) : new Date('2000-01-01');
      const to = query.to ? new Date(query.to + 'T23:59:59.999Z') : new Date();
      where.createdAt = Between(from, to);
    }

    const rows = await this.usageRepo.find({
      where,
      order: { createdAt: 'DESC' },
      take: 100000,
    });

    const userIds = [...new Set(rows.map((u) => u.userId))];
    const users = userIds.length
      ? await this.usageRepo.manager.find(User, {
          where: userIds.map((id) => ({ id })),
          select: ['id', 'userName'],
        })
      : [];
    const userMap = new Map(users.map((u) => [u.id, u.userName]));

    const BOM = '﻿';
    const header =
      'id,userId,userName,provider,model,promptTokens,completionTokens,totalTokens,createdAt';
    const csvRows = rows.map((r) =>
      [
        r.id,
        r.userId,
        `"${userMap.get(r.userId) || '未知'}"`,
        r.provider,
        r.model,
        r.promptTokens,
        r.completionTokens,
        r.totalTokens,
        r.createdAt instanceof Date ? r.createdAt.toISOString() : r.createdAt,
      ].join(','),
    );
    return BOM + [header, ...csvRows].join('\n');
  }
}
