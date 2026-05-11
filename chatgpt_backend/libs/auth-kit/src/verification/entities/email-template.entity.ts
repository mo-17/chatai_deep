import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';

/** 邮件模板，表 ak_email_templates */
@Entity('ak_email_templates')
export class EmailTemplate {
  @PrimaryGeneratedColumn()
  id: number;

  /** 模板键（如 'code-login', 'code-register' 等） */
  @Column({ type: 'varchar', length: 50, unique: true })
  key: string;

  /** 邮件主题 */
  @Column({ type: 'varchar', length: 200 })
  subject: string;

  /** HTML 正文 */
  @Column({ type: 'text' })
  body: string;

  @UpdateDateColumn()
  updatedAt: Date;
}
