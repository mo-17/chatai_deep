import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Banner } from './banner.entity';

@Injectable()
export class NoticeService {
  constructor(
    @InjectRepository(Banner)
    private bannerRepo: Repository<Banner>,
  ) {}

  async getBanners(pageIndex = 1, pageSize = 10) {
    const [list, total] = await this.bannerRepo.findAndCount({
      where: { enabled: true },
      order: { sticky: 'DESC', createTime: 'DESC' },
      take: pageSize,
      skip: (pageIndex - 1) * pageSize,
    });
    return {
      code: 0,
      data: { list, total, page: pageIndex, pageSize },
    };
  }
}
