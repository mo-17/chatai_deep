import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/safe_url_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SafeUrlFetcher production transport', () {
    test('HTTPS connects to the validated IP but verifies the URL hostname',
        () async {
      final server = await _secureServer();
      final requestedAddresses = <InternetAddress>[];
      final requestedPorts = <int>[];
      try {
        final fetcher = SafeUrlFetcher(
          resolver: (host) async {
            expect(host, 'example.test');
            return [InternetAddress('93.184.216.34')];
          },
          securityContext: _trustedClientContext(),
          socketStarter: (address, port) {
            requestedAddresses.add(address);
            requestedPorts.add(port);
            return Socket.startConnect(
              InternetAddress.loopbackIPv4,
              server.port,
            );
          },
        );

        expect(
          await fetcher.fetch(Uri.parse('https://example.test/article')),
          contains('secure response'),
        );
        expect(
          requestedAddresses.single.address,
          '93.184.216.34',
        );
        expect(requestedPorts.single, 443);
      } finally {
        await server.close(force: true);
      }
    });

    test('certificate for another hostname is rejected', () async {
      final server = await _secureServer();
      try {
        final fetcher = SafeUrlFetcher(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          securityContext: _trustedClientContext(),
          socketStarter: (_, __) => Socket.startConnect(
            InternetAddress.loopbackIPv4,
            server.port,
          ),
        );

        await expectLater(
          fetcher.fetch(Uri.parse('https://wrong.test/')),
          throwsA(isA<TlsException>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('HTTPS never emits a plaintext HTTP request on the pinned socket',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final firstBytes = Completer<List<int>>();
      final subscription = server.listen((socket) {
        socket.listen((bytes) {
          if (!firstBytes.isCompleted) firstBytes.complete(List.of(bytes));
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');
          socket.destroy();
        });
      });
      try {
        final fetcher = SafeUrlFetcher(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          socketStarter: (_, __) => Socket.startConnect(
            InternetAddress.loopbackIPv4,
            server.port,
          ),
        );

        await expectLater(
          fetcher.fetch(Uri.parse('https://example.test/')),
          throwsA(anything),
        );
        final bytes =
            await firstBytes.future.timeout(const Duration(seconds: 2));
        expect(bytes, isNotEmpty);
        expect(bytes.first, 0x16,
            reason: 'first record must be a TLS handshake');
        expect(utf8.decode(bytes, allowMalformed: true),
            isNot(startsWith('GET ')));
      } finally {
        await subscription.cancel();
        await server.close();
      }
    });
  });
}

Future<HttpServer> _secureServer() async {
  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(_certificatePem))
    ..usePrivateKeyBytes(utf8.encode(_privateKeyPem));
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  server.listen((request) async {
    request.response.headers.contentType = ContentType.text;
    request.response.write('secure response');
    await request.response.close();
  });
  return server;
}

SecurityContext _trustedClientContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(_rootCertificatePem));

// Test-only CA and serverAuth leaf for example.test. No production credentials.
// Separate serverAuth leaf with 365-day validity: macOS rejects the previous
// ten-year leaf. Renew this test-only leaf before 2027-09-17; do not bypass
// certificate or hostname checks in either the fixture or production transport.
const _certificatePem = '''
-----BEGIN CERTIFICATE-----
MIIDBjCCAe6gAwIBAgIJALlB1fd5ww+BMA0GCSqGSIb3DQEBCwUAMB4xHDAaBgNV
BAMME0NoYXRhaSB0ZXN0IHJvb3QgQ0EwHhcNMjYwOTE3MTkyMjU0WhcNMjcwOTE3
MTkyMjU0WjAXMRUwEwYDVQQDDAxleGFtcGxlLnRlc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDHRHGNYYeXPTI2e1V3gJj2atvup4Br325T23lXcbB8
3qzvjICe/Q73zFl/If3zcf8mCKvkjM5kvA+sH1a/p2kejGb4kAs85j/qmB695baM
2+su5qddie/gsu1oOxDUlgstaugfEd9FqBgQp28xG65dVHAKP1WnA+7aqIXG208G
L6eQblC5aBiKaFeJOMzdVVX0zwd7cL5sRTsJAMGpd37g/ncVhWr2/MLhd3oigI5I
g+aYOfActtGqXmC0/t7WeTMNsEA0st7qlDiHzCq9TB8nzHtqWxBwqcFf7W6saplD
kJr7U90ccHSH2Gm8s1rpHBhde+rXg+/xF+E4bUWou40RAgMBAAGjTjBMMAwGA1Ud
EwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBcG
A1UdEQQQMA6CDGV4YW1wbGUudGVzdDANBgkqhkiG9w0BAQsFAAOCAQEAeD8YThiB
FAwr37D5QV28kg+TovJeN054xHq+JGlJ7Xzb4UF7GmQWFW4bEmECDj9eL4J+sYI0
d1N2seDNg9uQGwuGrm+nsqgVOAULwhABP/+GDpGUvxHdpu/o9ZShU6GbiKzPnDGt
/aJbDF38APlqxYFhdmt4x0KPLuQ1IrQB02yN3KLTPqgII3nWmtOihTGD9EEowSJ+
L4aUApFTrRt8UTolwP23XB/QQgYR6J/1YTvmt0Lk/FRMfVmXIC8IrmvdK6dR6gtG
1f4XebgQl/FKtyU/0lwZeUtihb3JhsAcUbRepTSRyiRRO43vxBw5jQ5Hu6t48XQW
1EKlKNzxS4S+CQ==
-----END CERTIFICATE-----
''';

const _privateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDHRHGNYYeXPTI2
e1V3gJj2atvup4Br325T23lXcbB83qzvjICe/Q73zFl/If3zcf8mCKvkjM5kvA+s
H1a/p2kejGb4kAs85j/qmB695baM2+su5qddie/gsu1oOxDUlgstaugfEd9FqBgQ
p28xG65dVHAKP1WnA+7aqIXG208GL6eQblC5aBiKaFeJOMzdVVX0zwd7cL5sRTsJ
AMGpd37g/ncVhWr2/MLhd3oigI5Ig+aYOfActtGqXmC0/t7WeTMNsEA0st7qlDiH
zCq9TB8nzHtqWxBwqcFf7W6saplDkJr7U90ccHSH2Gm8s1rpHBhde+rXg+/xF+E4
bUWou40RAgMBAAECggEAEH6w66QkJjfRnULuWzsQ7m0AEaxZ7BQNvPFRBRULJ/sC
072MtBx8jbSjv+tfazSHi21yVTP2rc4HehcKBklkYTv8Fh1OYNcqeU/oU43dY6Gc
wUAkoJCXg8Er99HT3dUhzbuoxVGkas60V0SU5rrE30LrF14QyAeCUSVcFY735qoL
v9cnCYuTsErWlXvacNZ1DUt2ljcwh8X0/eNDRR34Tv1lPGjgmAl9VWyBVtw4pFAc
ErSNcqWm/kL7QmUrqw1FD2r900Uh4YcbqN/W38E0d+pF2EqjI5l2W+MlkqE5FCwL
JRCWsFjnaQG8L/vo1e7eCPP3w/6xP70JDS7FLaz89QKBgQDvExTnw0MRbY9ach4s
yZBjQoWOvNM8qci7O0oShpd5tvsnS/NR8PRnf6m9AISHFMRInRgycyy+zhAXywIG
Yr6b2jAMFbsC7cjrb2yyrFMoB275kundbqzfCcVG4Npi6Ph72y7ZoJ22qKZTzaAw
8vltF5IgjonCZ5cgNsmP+nzMKwKBgQDVX+hyCTooSu0k5wuHRTpoESjepALhdexA
9InAuEORma0KJUz3PYXcrw8/i7Vc0yoatcgfMUABBvc+a5hsqXrhWYhbFjFsNoG5
iUXDTfvtfoT37cl4LPLVuHmI35TBlv2EAqoA8EHuJn3Ef8BnLEZwlBrtWSQ2MxYp
/dNafZXhswKBgQCnis/Tu9t8kzMrR14uNPOjHDNM3LeMg8/QprQ6V2hAPCO2Xlue
ySX+glEJyxsVL1B/MtiKQnzRGsfcZMB+iSTbRAT38yKj4tAzblrWvD1qiAsVjAeo
zq8Hf2lpSprBRlMdOXWTviPIplgp0qi4pQ53jVUyy7FvM/mM8dg/tmNPEQKBgQCa
D4iOpdjm9Mpq5aNuRO7Z6uHedv9ZeMJfV/EKREENJK9K7wm2TiaT45YX5LDLV/BD
ntLiqrWyyCvGVvuUIX6GrRWF5u1CW8yogNPtIyZuIPay6G6aJaIj6/FcgUovyOw8
34uN5+tCn2oZccAi/lXRvS4AB2fc9l/fa9Sptpl8fwKBgQCCo+IIzEK/ymEnNHIG
gTpJ1TNFvw9+pyu6pBBT+txRdI2oWL5QbgoKOr4j9xxxfyr8Qc9VzE+caP6LVz/Z
JLl1KOAo3S25nZ0hUqm+0JRkkRmi+cg4VaDopJd5Y3oOe2L0Abjnz3F/+Jrk+8Dk
BBSoPDQ34oDh0xBDSTOqafvNIg==
-----END PRIVATE KEY-----
''';

const _rootCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIIC4jCCAcqgAwIBAgIJAK/mVsc4+WVPMA0GCSqGSIb3DQEBCwUAMB4xHDAaBgNV
BAMME0NoYXRhaSB0ZXN0IHJvb3QgQ0EwHhcNMjYwOTE3MTkyMTI3WhcNMzYwOTE0
MTkyMTI3WjAeMRwwGgYDVQQDDBNDaGF0YWkgdGVzdCByb290IENBMIIBIjANBgkq
hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkmJ9snjgMKgUAhPoNk1NzKMWrPqJmGjK
/UVQfRlXblNj+esXWhb3CqAVARh6bsy7ACCFCzSC2PSEp4ziPWN9aWHM7kbPp0y5
bDKdbNlwwkOeRRuM/qmIemTRGHZp/jv/OBGDhzT76O7JzZwiMZHxtbhVoNIJ5geV
cs9iXXEsT9SfiNawZKg0BHHEPneNppu44GOxBnT300fq2Ar3n+lvMxlx9IuSi1br
jL5KUY3m/n7rO45/qf47BaoY2F5oywIxPpyZG7vx/zTgoQ/emGmzEzl7fjAbXlcb
1m4tZcdnqx3/BvcxdUbDaJnJzeUpgtXkCseDgqmYL6CfCsuReT5S8wIDAQABoyMw
ITAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsF
AAOCAQEAUhd5NtaVpdmVJsE/1Amu4I5GywAsVXtuJ5uNMXuBT34kl4NRboUTMa9m
X02OOw/YzmBkEw7xyVSkVVyckmt9CqWMhrdTzuSbpGlhLEd8tz1Zv93xq74vtv3i
YCZoLxPV1v7e6Nqv7TleBQyKyjRx0aPGbJfV0DQWGyeIpDrMM1YddlWEU8xQjmWq
a/qtaw2a4qF8P+3qQxWIkBhijIYMOMoMqxe8bC7UDC4FXx7prLxEXvQ+GqWesfov
JYe66r3lw7aT02G424f1s/29vcBqvfZ49aMjJFuhiy6J2hRaxvzem8J9/PAyszHH
KZ60g0hBIjW+AO6Tryk3zeb7asqyYQ==
-----END CERTIFICATE-----
''';
