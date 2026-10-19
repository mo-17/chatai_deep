import { Column, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';
export type TeamRole = 'owner' | 'editor' | 'viewer';
export interface TeamDocument {
  uid: string;
  title: string;
  revision: number;
  archived: boolean;
  createdAt: number;
  updatedAt: number;
  chunks: { seq: number; pageNumber: number | null; content: string }[];
}
export interface TeamAudit {
  at: number;
  actor: number;
  action: string;
  target: string;
}
@Entity('knowledge_team')
@Index(['ownerId'])
export class TeamWorkspace {
  @PrimaryGeneratedColumn('uuid') id: string;
  @Column() ownerId: number;
  @Column({ length: 80 }) name: string;
  @Column({ default: 1 }) revision: number;
  @Column('jsonb', { default: {} }) members: Record<string, TeamRole>;
  @Column('jsonb', { default: {} }) documents: Record<string, TeamDocument>;
  @Column('jsonb', { default: [] }) answers: Record<string, unknown>[];
  @Column('jsonb', { default: [] }) audit: TeamAudit[];
  @Column('bigint') createdAt: number;
}
@Entity('knowledge_team_invite')
export class TeamInvite {
  @PrimaryGeneratedColumn('uuid') id: string;
  @Index() @Column('uuid') teamId: string;
  @Index({ unique: true })
  @Column({ length: 64, select: false })
  codeHash: string;
  @Column({ length: 10 }) role: 'editor' | 'viewer';
  @Column('bigint') expiresAt: number;
  @Column({ default: false }) consumed: boolean;
}
