import { Column, Entity, Index, PrimaryColumn } from 'typeorm';

@Entity('access_requests')
@Index(['day', 'userId'])
@Index(['userId', 'activeUntil'])
export class AccessRequest {
  @PrimaryColumn('uuid') id: string;
  @Column() userId: number;
  @Column({ type: 'date' }) day: string;
  @Column() model: string;
  @Column({ default: 0 }) chargedTokens: number;
  @Column({ type: 'timestamptz', nullable: true }) activeUntil: Date | null;
  @Column({ type: 'timestamptz', default: () => 'now()' }) createdAt: Date;
}
