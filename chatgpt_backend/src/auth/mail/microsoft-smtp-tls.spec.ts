import * as net from 'node:net';
import * as tls from 'node:tls';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { EmailMicrosoftSender } from '../../../libs/auth-kit/src/verification/senders/email-microsoft.sender';
import type { MicrosoftSmtpService } from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.service';
import type { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import { deferred } from './microsoft-private-pg.fixture';
const cert = readFileSync(
    join(__dirname, 'fixtures/microsoft-smtp-synthetic-cert.pem'),
  ),
  key = readFileSync(
    join(__dirname, 'fixtures/microsoft-smtp-synthetic-key.pem'),
  );
/** 本测试专用自签名fixture，不是微软或用户凭据。 */
describe('O1 local synthetic STARTTLS/XOAUTH2 and actual socket cancellation', () => {
  jest.setTimeout(15000);
  let server: net.Server,
    sockets: Set<net.Socket>,
    port: number,
    auths: number,
    connections: number,
    submissions: number,
    wasTls: boolean,
    authBeforeTls: boolean,
    closeObserved: number;
  let mode: 'ok' | 'no_starttls' | 'hold_data' | 'hold_greeting',
    listener: ((key?: string) => void) | undefined,
    entered: ReturnType<typeof deferred>,
    sender: EmailMicrosoftSender;
  beforeEach(async () => {
    sockets = new Set();
    auths = 0;
    connections = 0;
    submissions = 0;
    closeObserved = 0;
    wasTls = false;
    authBeforeTls = false;
    mode = 'ok';
    entered = deferred();
    server = net.createServer((socket) => {
      connections++;
      sockets.add(socket);
      socket.on('error', () => {});
      socket.on('close', () => {
        sockets.delete(socket);
        closeObserved++;
      });
      function attach(stream: net.Socket | tls.TLSSocket, secure: boolean) {
        let buffer = '',
          data = false;
        stream.on('error', () => {});
        stream.on('data', (chunk) => {
          buffer += String(chunk);
          for (;;) {
            const index = buffer.indexOf('\r\n');
            if (index < 0) break;
            const line = buffer.slice(0, index);
            buffer = buffer.slice(index + 2);
            if (data) {
              if (line === '.') {
                submissions++;
                data = false;
                if (mode === 'hold_data') {
                  entered.resolve();
                } else stream.write('250 synthetic accepted\r\n');
              }
              continue;
            }
            if (line.startsWith('EHLO'))
              stream.write(
                '250-synthetic\r\n' +
                  (!secure && mode !== 'no_starttls'
                    ? '250-STARTTLS\r\n'
                    : '') +
                  '250 AUTH XOAUTH2\r\n',
              );
            else if (line === 'STARTTLS') {
              if (mode === 'no_starttls') {
                stream.write('454 synthetic TLS unavailable\r\n');
                continue;
              }
              stream.write('220 synthetic start TLS\r\n');
              stream.removeAllListeners('data');
              const encrypted = new tls.TLSSocket(socket, {
                isServer: true,
                secureContext: tls.createSecureContext({ key, cert }),
                minVersion: 'TLSv1.2',
              });
              sockets.add(encrypted);
              encrypted.on('close', () => sockets.delete(encrypted));
              attach(encrypted, true);
            } else if (line.startsWith('AUTH')) {
              auths++;
              wasTls = secure;
              authBeforeTls = !secure;
              expect(line).toBe(
                'AUTH XOAUTH2 ' +
                  Buffer.from(
                    'user=sender@synthetic.invalid\x01auth=Bearer synthetic-opaque-access\x01\x01',
                  ).toString('base64'),
              );
              stream.write('235 synthetic authenticated\r\n');
            } else if (
              line.startsWith('MAIL FROM') ||
              line.startsWith('RCPT TO')
            )
              stream.write('250 synthetic ok\r\n');
            else if (line === 'DATA') {
              data = true;
              stream.write('354 synthetic data\r\n');
            } else if (line === 'QUIT') {
              stream.end('221 synthetic bye\r\n');
            }
          }
        });
      }
      attach(socket, false);
      if (mode !== 'hold_greeting') socket.write('220 synthetic ready\r\n');
    });
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const address = server.address();
    if (!address || typeof address === 'string')
      throw Error('synthetic_smtp_required');
    port = address.port;
    const service = {
      access: jest.fn().mockResolvedValue({
        token: 'synthetic-opaque-access',
        generation: 1,
        fence: 1,
        configRevision: 1,
        expiresAt: Date.now() + 3600000,
      }),
      assertAccess: jest.fn().mockResolvedValue(undefined),
      subscribe: (l: (key?: string) => void) => {
        listener = l;
        return () => {
          listener = undefined;
        };
      },
    };
    sender = new EmailMicrosoftSender(
      {
        id: 1,
        key: 'generic',
        authMode: 'microsoft_oauth',
        configRevision: 1,
        fromName: 'fixture',
        fromAddress: 'sender@synthetic.invalid',
      } as SmtpProvider,
      service as unknown as MicrosoftSmtpService,
      {
        connect: () => net.createConnection({ host: '127.0.0.1', port }),
        tls: { ca: cert },
      },
    );
  });
  afterEach(async () => {
    sender?.close();
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((r) => server.close(() => r()));
  });
  it('requires verified STARTTLS then sends opaque XOAUTH2 exactly once', async () => {
    await sender.send(
      'target@synthetic.invalid',
      'synthetic',
      '<p>synthetic</p>',
    );
    expect(auths).toBe(1);
    expect(wasTls).toBe(true);
    expect(authBeforeTls).toBe(false);
    expect(connections).toBe(1);
    expect(submissions).toBe(1);
  });
  it('server lacking STARTTLS never receives auth token', async () => {
    mode = 'no_starttls';
    await expect(
      sender.send('target@synthetic.invalid', 'synthetic', 'synthetic'),
    ).rejects.toThrow();
    expect(auths).toBe(0);
    expect(submissions).toBe(0);
    expect(connections).toBe(1);
  });
  it('local disconnect cancels real active TLS socket; accepted DATA is unknown and not retried', async () => {
    mode = 'hold_data';
    const result = sender.send(
      'target@synthetic.invalid',
      'synthetic',
      'synthetic',
    );
    const rejected = result.then(
      () => false,
      (e) => (e as { deliveryStatus: string }).deliveryStatus === 'unknown',
    );
    await entered.promise;
    listener?.('generic');
    expect(await rejected).toBe(true);
    await new Promise((r) => setTimeout(r, 100));
    expect(closeObserved).toBeGreaterThan(0);
    expect(connections).toBe(1);
    expect(submissions).toBe(1);
  });
  it('close during greeting destroys active plain socket with no retry', async () => {
    mode = 'hold_greeting';
    const result = sender.send(
      'target@synthetic.invalid',
      'synthetic',
      'synthetic',
    );
    const rejected = result.then(
      () => false,
      (e) => (e as { deliveryStatus: string }).deliveryStatus === 'unknown',
    );
    while (!connections) await new Promise((r) => setTimeout(r, 5));
    sender?.close();
    expect(await rejected).toBe(true);
    await new Promise((r) => setTimeout(r, 100));
    expect(closeObserved).toBeGreaterThan(0);
    expect(connections).toBe(1);
    expect(auths).toBe(0);
  });
  it('greeting timeout is bounded and does not retry SMTP', async () => {
    mode = 'hold_greeting';
    const begin = Date.now();
    await expect(
      sender.send('target@synthetic.invalid', 'synthetic', 'synthetic'),
    ).rejects.toThrow();
    expect(Date.now() - begin).toBeLessThan(9000);
    expect(connections).toBe(1);
    expect(auths).toBe(0);
  });
});
