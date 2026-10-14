import tls from 'node:tls';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { EmailSmtpSender } from '../../../libs/auth-kit/src/verification/senders/email-smtp.sender';
import type { MailDeliveryError } from '../../../libs/auth-kit/src/verification/senders/mail-delivery.error';
const cert = readFileSync(
    join(__dirname, 'fixtures/microsoft-smtp-synthetic-cert.pem'),
  ),
  key = readFileSync(
    join(__dirname, 'fixtures/microsoft-smtp-synthetic-key.pem'),
  );
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
/** 实际TLS/SMTP/socket；仅每封30s总deadline的callback由fixture受控触发，不等待真实30s。 */
describe('P2 ordinary SMTP per-send cancellation isolation over synthetic TLS', () => {
  jest.setTimeout(10000);
  let server: tls.Server,
    sender: EmailSmtpSender,
    sockets: Set<tls.TLSSocket>,
    connections: number,
    submissions: number,
    closed: Set<tls.TLSSocket>,
    ready: Array<ReturnType<typeof deferred>>,
    replies: Map<number, tls.TLSSocket>,
    deadlines: Array<() => void>;
  beforeEach(async () => {
    sockets = new Set();
    connections = 0;
    submissions = 0;
    closed = new Set();
    ready = [deferred(), deferred()];
    replies = new Map();
    deadlines = [];
    server = tls.createServer(
      { key, cert, minVersion: 'TLSv1.2' },
      (socket) => {
        const id = connections++,
          closedForTest = closed;
        sockets.add(socket);
        socket.on('error', () => {});
        socket.on('close', () => {
          sockets.delete(socket);
          closedForTest.add(socket);
        });
        socket.write('220 synthetic SMTP\r\n');
        let buffer = '',
          data = false;
        socket.on('data', (chunk) => {
          buffer += String(chunk);
          for (;;) {
            const index = buffer.indexOf('\r\n');
            if (index < 0) break;
            const line = buffer.slice(0, index);
            buffer = buffer.slice(index + 2);
            if (data) {
              if (line === '.') {
                data = false;
                submissions++;
                replies.set(id, socket);
                ready[id].resolve();
              }
              continue;
            }
            if (line.startsWith('EHLO'))
              socket.write('250-synthetic\r\n250 AUTH PLAIN\r\n');
            else if (line.startsWith('AUTH PLAIN'))
              socket.write('235 synthetic authenticated\r\n');
            else if (line.startsWith('MAIL FROM') || line.startsWith('RCPT TO'))
              socket.write('250 synthetic OK\r\n');
            else if (line === 'DATA') {
              data = true;
              socket.write('354 synthetic data\r\n');
            } else if (line === 'QUIT') socket.end('221 synthetic bye\r\n');
          }
        });
      },
    );
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const addr = server.address();
    if (!addr || typeof addr === 'string')
      throw Error('synthetic_listener_required');
    const originalConnect = tls.connect.bind(tls) as (
      options: tls.ConnectionOptions,
    ) => tls.TLSSocket;
    jest.spyOn(tls, 'connect').mockImplementation(((
      options: tls.ConnectionOptions,
    ) =>
      originalConnect({
        ...options,
        host: '127.0.0.1',
        port: addr.port,
        servername: 'smtp-mail.outlook.com',
        ca: cert,
      })) as typeof tls.connect);
    const originalTimer = global.setTimeout.bind(global) as typeof setTimeout;
    jest
      .spyOn(global, 'setTimeout')
      .mockImplementation(
        (
          callback: (...args: unknown[]) => void,
          ms?: number,
          ...args: unknown[]
        ) => {
          if (ms === 30000) {
            deadlines.push(() => callback(...args));
            return originalTimer(() => {}, 60000);
          }
          return originalTimer(callback, ms, ...args);
        },
      );
    sender = new EmailSmtpSender({
      host: 'smtp-mail.outlook.com',
      port: addr.port,
      secure: true,
      user: 'sender@synthetic.invalid',
      pass: 'synthetic-password',
      fromName: 'fixture',
      fromAddress: 'sender@synthetic.invalid',
    });
  });
  afterEach(async () => {
    sender?.close();
    for (const s of sockets) s.destroy();
    await new Promise<void>((r) => server.close(() => r()));
    jest.restoreAllMocks();
  });
  const send = (label: string) =>
    sender.send('target@synthetic.invalid', label, 'synthetic').then(
      () => ({ ok: true, status: 'sent' }),
      (e) => ({ ok: false, status: (e as MailDeliveryError).deliveryStatus }),
    );
  it('A deadline cancels only A while later B succeeds, with one SMTP attempt each', async () => {
    const a = send('A');
    await ready[0].promise;
    const b = send('B');
    await ready[1].promise;
    expect(deadlines).toHaveLength(2);
    deadlines[0]();
    expect(await a).toEqual({ ok: false, status: 'unknown' });
    replies.get(1)!.write('250 synthetic accepted B\r\n');
    expect(await b).toEqual({ ok: true, status: 'sent' });
    expect(connections).toBe(2);
    expect(submissions).toBe(2);
  });
  it('global close cancels both actual TLS sockets, prevents new sends and never retries', async () => {
    const a = send('A');
    await ready[0].promise;
    const b = send('B');
    await ready[1].promise;
    sender.close();
    expect(await a).toEqual({ ok: false, status: 'unknown' });
    expect(await b).toEqual({ ok: false, status: 'unknown' });
    await new Promise((r) => setTimeout(r, 100));
    expect(closed.size).toBe(2);
    await expect(
      sender.send('target@synthetic.invalid', 'C', 'synthetic'),
    ).rejects.toThrow();
    expect(connections).toBe(2);
    expect(submissions).toBe(2);
  });
});
