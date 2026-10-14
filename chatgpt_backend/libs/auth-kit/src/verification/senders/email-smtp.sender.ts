import * as net from 'node:net';
import * as tls from 'node:tls';
import * as nodemailer from 'nodemailer';
import type SMTPTransport from 'nodemailer/lib/smtp-transport';
import { IEmailSender } from './email-sender.interface';
import { MailDeliveryError, safeMailFailure } from './mail-delivery.error';

/** 普通SMTP每封邮件独立transport/socket；缓存sender只保存配置及全局关闭状态。 */
export class EmailSmtpSender implements IEmailSender {
  private readonly pending = new Set<() => void>();
  private closed = false;
  constructor(
    private readonly config: {
      host: string;
      port: number;
      secure: boolean;
      user: string;
      pass: string;
      fromName: string;
      fromAddress: string;
    },
  ) {}

  async send(to: string, subject: string, html: string): Promise<void> {
    if (this.closed)
      throw new MailDeliveryError('smtp_delivery_unknown', 'unknown');
    const config = this.config,
      sockets = new Set<net.Socket>();
    let transporter: nodemailer.Transporter | undefined,
      cancelled = false,
      released = false;
    let rejectAbort: (error: unknown) => void = () => {};
    const aborted = new Promise<never>((_, reject) => {
      rejectAbort = reject;
    });
    const release = () => {
      for (const socket of sockets) socket.destroy();
      if (!released) {
        released = true;
        transporter?.close();
      }
    };
    const cancel = () => {
      cancelled = true;
      release();
      rejectAbort(new MailDeliveryError('smtp_delivery_unknown', 'unknown'));
    };
    this.pending.add(cancel);
    const timer = setTimeout(cancel, 30000);
    try {
      const options: SMTPTransport.Options = {
        host: config.host,
        port: config.port,
        secure: config.secure,
        auth: { user: config.user, pass: config.pass },
        connectionTimeout: 10000,
        greetingTimeout: 10000,
        socketTimeout: 15000,
        logger: false,
        debug: false,
        getSocket: (_options, callback) => {
          if (this.closed || cancelled) {
            callback(
              new MailDeliveryError('smtp_delivery_unknown', 'unknown'),
              {},
            );
            return;
          }
          const socket = config.secure
            ? tls.connect({
                host: config.host,
                port: config.port,
                servername: config.host,
                rejectUnauthorized: true,
                minVersion: 'TLSv1.2',
              })
            : net.createConnection({ host: config.host, port: config.port });
          sockets.add(socket);
          let returned = false;
          socket.once('error', (error) => {
            if (!returned) {
              returned = true;
              callback(safeMailFailure(error), {});
            }
          });
          socket.once(config.secure ? 'secureConnect' : 'connect', () => {
            if (!returned) {
              returned = true;
              callback(null, { connection: socket, secured: config.secure });
            }
          });
          socket.once('close', () => sockets.delete(socket));
        },
      };
      transporter = nodemailer.createTransport(options);
      await Promise.race([
        transporter.sendMail({
          from: { name: config.fromName, address: config.fromAddress },
          to,
          subject,
          html,
        }),
        aborted,
      ]);
    } catch (error) {
      throw safeMailFailure(error);
    } finally {
      clearTimeout(timer);
      this.pending.delete(cancel);
      release();
    }
  }
  close(): void {
    this.closed = true;
    for (const cancel of this.pending) cancel();
  }
}
