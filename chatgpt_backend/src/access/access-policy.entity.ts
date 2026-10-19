import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity('access_policy')
export class AccessPolicy {
  @PrimaryColumn({ default: 1 }) id: number;
  @Column({ default: false }) limitsEnabled: boolean;
  @Column({ default: false }) trialEnabled: boolean;
  @Column({ default: '' }) trialProviderCode: string;
  @Column({ default: '' }) trialModel: string;
  @Column({ default: 100 }) dailyRequests: number;
  @Column({ default: 10000 }) dailyTokens: number;
  @Column({ default: 100000 }) globalDailyTokens: number;
  @Column({ default: 500 }) globalDailyRequests: number;
  @Column({ default: 1 }) maxConcurrent: number;
  @Column({ default: 2048 }) maxOutputTokens: number;
  @Column({ default: true }) requireVerifiedEmail: boolean;
  @Column({ default: 6 }) requestsPerMinute: number;
  @Column({ default: 4 }) globalMaxConcurrent: number;
}
