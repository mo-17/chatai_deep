import * as nodemailer from 'nodemailer';
import * as net from 'node:net';
import type { ConnectionOptions } from 'node:tls';
import type { Options } from 'nodemailer/lib/smtp-transport';
import { SmtpProvider } from '../entities/smtp-provider.entity';
import {
  MicrosoftSmtpService,
  type MicrosoftAccess,
} from '../../microsoft/microsoft-smtp.service';
import { MailDeliveryError, safeMailFailure } from './mail-delivery.error';
import type { IEmailSender } from './email-sender.interface';
/** 仅供代码注入合成TLS服务；生产不接受env/request指定端点。 */
export interface MicrosoftSmtpSocketFixture {
  connect?: (options: net.NetConnectOpts) => net.Socket;
  tls?: Pick<ConnectionOptions, 'ca'>;
}
export class EmailMicrosoftSender implements IEmailSender {
  private readonly pending = new Set<() => void>();
  constructor(
    private readonly provider: SmtpProvider,
    private readonly microsoft: MicrosoftSmtpService,
    private readonly fixture: MicrosoftSmtpSocketFixture = {},
  ) {}
  async send(to: string, subject: string, html: string): Promise<void> {
    const p = this.provider;
    let access: MicrosoftAccess;
    try {
      access = await this.microsoft.access(p);
    } catch {
      throw new MailDeliveryError(
        'microsoft_authorization_unavailable',
        'failed',
      );
    }
    let cancelled = false;
    const sockets = new Set<net.Socket>();
    let rejectAbort: (reason: unknown) => void = () => {};
    const aborted = new Promise<never>((_, reject) => {
      rejectAbort = reject;
    });
    const cancel = () => {
      cancelled = true;
      for (const socket of sockets) socket.destroy();
      rejectAbort(new MailDeliveryError('smtp_delivery_unknown', 'unknown'));
    };
    this.pending.add(cancel);
    const unsubscribe = this.microsoft.subscribe((key) => {
      if (!key || key === p.key) cancel();
    });
    let checking = false;
    const poll = setInterval(() => {
      if (checking) return;
      checking = true;
      void this.microsoft
        .assertAccess(p, access)
        .catch(cancel)
        .finally(() => {
          checking = false;
        });
    }, 250);
    const timer = setTimeout(cancel, 20000);
    const options: Options = {
      host: 'smtp-mail.outlook.com',
      port: 587,
      secure: false,
      requireTLS: true,
      auth: { type: 'OAuth2', user: p.fromAddress, accessToken: access.token },
      tls: {
        ...this.fixture.tls,
        rejectUnauthorized: true,
        minVersion: 'TLSv1.2',
        servername: 'smtp-mail.outlook.com',
      },
      connectionTimeout: 5000,
      greetingTimeout: 5000,
      socketTimeout: 10000,
      logger: false,
      debug: false,
      getSocket: (_options, callback) => {
        // DB最终复核后才打开固定SMTP socket；不向任意host外送token。
        void this.microsoft
          .assertAccess(p, access)
          .then(() => {
            if (cancelled) {
              callback(
                new MailDeliveryError('smtp_delivery_unknown', 'unknown'),
                {},
              );
              return;
            }
            let socket: net.Socket;
            try {
              socket = (this.fixture.connect ?? net.createConnection)({
                host: 'smtp-mail.outlook.com',
                port: 587,
              });
            } catch {
              callback(
                new MailDeliveryError('smtp_delivery_unknown', 'unknown'),
                {},
              );
              return;
            }
            sockets.add(socket);
            let returned = false;
            socket.once('error', () => {
              if (!returned) {
                returned = true;
                callback(
                  new MailDeliveryError('smtp_delivery_unknown', 'unknown'),
                  {},
                );
              }
            });
            socket.once('connect', () => {
              if (!returned) {
                returned = true;
                callback(null, { connection: socket, secured: false });
              }
            });
            socket.once('close', () => sockets.delete(socket));
          })
          .catch(() =>
            callback(
              new MailDeliveryError('microsoft_connection_stale', 'failed'),
              {},
            ),
          );
      },
    };
    const transporter = nodemailer.createTransport(options);
    try {
      await Promise.race([
        transporter.sendMail({
          from: { name: p.fromName, address: p.fromAddress },
          to,
          subject,
          html,
        }),
        aborted,
      ]);
    } catch (e) {
      throw safeMailFailure(e);
    } finally {
      clearTimeout(timer);
      clearInterval(poll);
      unsubscribe();
      this.pending.delete(cancel);
      for (const s of sockets) s.destroy();
      transporter.close();
    }
  }
  close(): void {
    for (const cancel of this.pending) cancel();
  }
}
