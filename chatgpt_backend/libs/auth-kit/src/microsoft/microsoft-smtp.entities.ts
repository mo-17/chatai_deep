import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity('ak_microsoft_smtp_connections')
export class MicrosoftSmtpConnection {
  @PrimaryColumn({ type: 'integer' }) providerId: number;
  @Column({ type: 'integer', default: 1 }) schemaVersion: number;
  @Column({ type: 'integer', default: 0 }) generation: number;
  @Column({ type: 'integer', default: 0 }) configRevision: number;
  @Column({ type: 'varchar', default: 'not_connected' }) status:
    | 'not_connected'
    | 'connected'
    | 'needs_reauth';
  @Column({ type: 'integer', nullable: true }) adminId: number | null;
  @Column({ type: 'integer', nullable: true }) securityVersion: number | null;
  @Column({ type: 'text', nullable: true }) subject: string | null;
  @Column({ type: 'text', nullable: true }) issuer: string | null;
  @Column({ type: 'varchar', length: 320, nullable: true }) emailHint:
    | string
    | null;
  @Column({ type: 'text', nullable: true }) accessEncrypted: string | null;
  @Column({ type: 'text', nullable: true }) refreshEncrypted: string | null;
  @Column({ type: 'timestamptz', nullable: true }) expiresAt: Date | null;
  @Column({ type: 'uuid', nullable: true }) leaseOwner: string | null;
  @Column({ type: 'timestamptz', nullable: true }) leaseExpiresAt: Date | null;
  @Column({ type: 'integer', default: 0 }) fence: number;
  @Column({ type: 'varchar', length: 64, nullable: true }) errorCode:
    | string
    | null;
}

@Entity('ak_microsoft_smtp_flows')
export class MicrosoftSmtpFlow {
  @PrimaryColumn({ type: 'uuid' }) id: string;
  @Column({ type: 'integer', default: 1 }) schemaVersion: number;
  @Column({ type: 'integer' }) providerId: number;
  @Column({ type: 'integer' }) generation: number;
  @Column({ type: 'integer' }) configRevision: number;
  @Column({ type: 'integer' }) adminId: number;
  @Column({ type: 'integer' }) securityVersion: number;
  @Column({ type: 'timestamptz' }) authorizationExpiresAt: Date;
  @Column({ type: 'char', length: 64 }) bearerHash: string;
  @Column({ type: 'char', length: 64 }) cookieHash: string;
  @Column({ type: 'char', length: 64, unique: true }) stateHash: string;
  @Column({ type: 'char', length: 64 }) nonceHash: string;
  @Column({ type: 'text' }) redirectUri: string;
  @Column({ type: 'text', nullable: true }) verifierEncrypted: string | null;
  @Column({ type: 'text', nullable: true }) codeEncrypted: string | null;
  @Column({ type: 'varchar' }) status:
    | 'started'
    | 'received'
    | 'exchanging'
    | 'connected'
    | 'failed'
    | 'unknown'
    | 'cancelled'
    | 'expired';
  @Column({ type: 'timestamptz' }) expiresAt: Date;
  @Column({ type: 'uuid', nullable: true }) leaseOwner: string | null;
  @Column({ type: 'timestamptz', nullable: true }) leaseExpiresAt: Date | null;
  @Column({ type: 'integer', default: 0 }) fence: number;
  @Column({ type: 'varchar', length: 64, nullable: true }) errorCode:
    | string
    | null;
}
