import 'package:chatgpt_app_core/backup/backup_settings_merge.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('脱敏备份恢复时补回本地 provider/search/MCP secrets', () {
    final local = AISettings.defaults();
    local.activeProvider.apiKey = 'local-provider-key';
    local
      ..tavilyApiKey = 'local-tavily-key'
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Local name',
          url: 'https://mcp.example/mcp',
          headers: {'Authorization': 'Bearer local-mcp-token'},
        ),
      ];
    final incoming = AISettings.defaults();
    incoming.activeProvider.apiKey = '';
    incoming
      ..tavilyApiKey = ''
      ..streamEnabled = false
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Imported name',
          url: 'https://mcp.example/mcp',
          headers: {},
        ),
      ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(merged.activeProvider.apiKey, 'local-provider-key');
    expect(merged.tavilyApiKey, 'local-tavily-key');
    expect(merged.streamEnabled, isFalse);
    expect(merged.mcpServers.single.name, 'Imported name');
    expect(merged.mcpServers.single.url, 'https://mcp.example/mcp');
    expect(merged.mcpServers.single.headers, {
      'Authorization': 'Bearer local-mcp-token',
    });
  });

  test('脱敏备份保持所有内置 provider 的同 endpoint 旧用户 key', () {
    final local = AISettings.defaults();
    for (var index = 0; index < local.providers.length; index += 1) {
      local.providers[index].apiKey = 'local-key-$index';
    }
    final incoming = AISettings.defaults();
    for (final provider in incoming.providers) {
      provider.apiKey = '';
    }

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(
      merged.providers.map((provider) => provider.apiKey),
      [
        for (var index = 0; index < local.providers.length; index += 1)
          'local-key-$index',
      ],
    );
  });

  test('备份内显式携带的非空 secrets 优先于本地值', () {
    final local = AISettings.defaults();
    local.activeProvider.apiKey = 'local-key';
    local.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Local',
        url: 'https://local.example/mcp',
        headers: {'Authorization': 'Bearer local'},
      ),
    ];
    final incoming = AISettings.defaults();
    incoming.activeProvider.apiKey = 'backup-key';
    incoming.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Imported',
        url: 'https://imported.example/mcp',
        headers: {'Authorization': 'Bearer backup'},
      ),
    ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(merged.activeProvider.apiKey, 'backup-key');
    expect(merged.mcpServers.single.headers['Authorization'], 'Bearer backup');
  });

  test('显式包含 API Keys 的备份以空值清除本地 secrets', () {
    final local = AISettings.defaults();
    local.activeProvider.apiKey = 'local-provider-key';
    local
      ..tavilyApiKey = 'local-tavily-key'
      ..exaApiKey = 'local-exa-key'
      ..bochaApiKey = 'local-bocha-key'
      ..zhipuApiKey = 'local-zhipu-key'
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Local',
          url: 'https://local.example/mcp',
          headers: {'Authorization': 'Bearer local'},
        ),
      ];
    final incoming = AISettings.defaults();
    incoming.activeProvider.apiKey = '';
    incoming
      ..tavilyApiKey = ''
      ..exaApiKey = ''
      ..bochaApiKey = ''
      ..zhipuApiKey = ''
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Imported',
          url: 'https://imported.example/mcp',
          headers: {},
        ),
      ];

    final merged = mergeImportedSettingsSecrets(
      incoming,
      local,
      incomingIncludesSecrets: true,
    );

    expect(merged.activeProvider.apiKey, isEmpty);
    expect(merged.tavilyApiKey, isEmpty);
    expect(merged.exaApiKey, isEmpty);
    expect(merged.bochaApiKey, isEmpty);
    expect(merged.zhipuApiKey, isEmpty);
    expect(merged.mcpServers.single.headers, isEmpty);
  });

  test('同 provider id 但 endpoint path、query 或 port 变化时不继承 API key', () {
    final local = AISettings.defaults();
    local.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://api.example.com/v1/chat/completions?tenant=local'
      ..apiKey = 'local-secret';

    for (final changedEndpoint in const [
      'http://api.example.com/v1/chat/completions?tenant=local',
      'https://other.example.com/v1/chat/completions?tenant=local',
      'https://api.example.com/proxy/v1/chat/completions?tenant=local',
      'https://api.example.com/v1/chat/completions?tenant=backup',
      'https://api.example.com:8443/v1/chat/completions?tenant=local',
      'https://user@api.example.com/v1/chat/completions?tenant=local',
      'https://api.example.com/v1/chat/completions?tenant=local#backup',
      'ftp://api.example.com/v1/chat/completions?tenant=local',
      'api.example.com/v1/chat/completions?tenant=local',
      'https://api.example.com:/v1/chat/completions?tenant=local',
      'https://@api.example.com/v1/chat/completions?tenant=local',
      '',
      'https://',
    ]) {
      final incoming = AISettings.defaults();
      incoming.providers.firstWhere((provider) => provider.id == 'openai')
        ..apiHost = changedEndpoint
        ..apiKey = '';

      final merged = mergeImportedSettingsSecrets(incoming, local);

      expect(
        merged.providers
            .firstWhere((provider) => provider.id == 'openai')
            .apiKey,
        isEmpty,
        reason: changedEndpoint,
      );
    }
  });

  test('同 provider/type 的等价 default-port 与 trailing-slash endpoint 继承 key', () {
    final local = AISettings.defaults();
    local.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://API.EXAMPLE.com:443/v1/'
      ..apiKey = 'local-secret';
    final incoming = AISettings.defaults();
    incoming.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://api.example.com/v1'
      ..apiKey = '';

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(
      merged.providers.firstWhere((provider) => provider.id == 'openai').apiKey,
      'local-secret',
    );
  });

  test('同 provider id 与 endpoint 但 type 变化时不继承 API key', () {
    final local = AISettings.defaults();
    local.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://api.example.com/v1'
      ..apiKey = 'local-secret';
    final incoming = AISettings.defaults();
    incoming.providers.firstWhere((provider) => provider.id == 'openai')
      ..type = 'azure-openai'
      ..apiHost = 'https://api.example.com/v1'
      ..apiKey = '';

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(
      merged.providers.firstWhere((provider) => provider.id == 'openai').apiKey,
      isEmpty,
    );
  });

  test('同 MCP id 但 URL path、query 或 port 变化时不继承 headers', () {
    final local = AISettings.defaults()
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Local',
          url: 'https://mcp.example.com/mcp?tenant=local',
          headers: {'Authorization': 'Bearer local-secret'},
        ),
      ];

    for (final changedUrl in const [
      'http://mcp.example.com/mcp?tenant=local',
      'https://other.example.com/mcp?tenant=local',
      'https://mcp.example.com/other?tenant=local',
      'https://mcp.example.com/mcp?tenant=backup',
      'https://mcp.example.com:8443/mcp?tenant=local',
      'https://user@mcp.example.com/mcp?tenant=local',
      'https://mcp.example.com/mcp?tenant=local#backup',
      'ftp://mcp.example.com/mcp?tenant=local',
      'mcp.example.com/mcp?tenant=local',
      'https://mcp.example.com:/mcp?tenant=local',
      'https://@mcp.example.com/mcp?tenant=local',
      '',
      'https://',
    ]) {
      final incoming = AISettings.defaults()
        ..mcpServers = [
          McpServerConfig(
            id: 'remote',
            name: 'Imported',
            url: changedUrl,
          ),
        ];

      final merged = mergeImportedSettingsSecrets(incoming, local);

      expect(merged.mcpServers.single.headers, isEmpty, reason: changedUrl);
    }
  });

  test('等价 default-port 与 trailing-slash MCP URL 继承整组 headers', () {
    final local = AISettings.defaults()
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Local',
          url: 'https://MCP.EXAMPLE.com:443/mcp/',
          headers: {
            'Authorization': 'Bearer local-secret',
            'X-Tenant': 'local',
          },
        ),
      ];
    final incoming = AISettings.defaults()
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Imported',
          url: 'https://mcp.example.com/mcp',
        ),
      ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(merged.mcpServers.single.headers, {
      'Authorization': 'Bearer local-secret',
      'X-Tenant': 'local',
    });
  });

  test('本地 provider 或 MCP id 重复时拒绝从歧义候选继承 secrets', () {
    final local = AISettings.defaults();
    final localProvider = local.providers.firstWhere(
      (provider) => provider.id == 'openai',
    )
      ..apiHost = 'https://api.example.com/v1'
      ..apiKey = 'first-local-secret';
    local.providers.add(
      localProvider.copy()
        ..name = 'Duplicate'
        ..apiKey = 'second-local-secret',
    );
    local.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'First',
        url: 'https://mcp.example.com/mcp',
        headers: {'Authorization': 'Bearer first'},
      ),
      McpServerConfig(
        id: 'remote',
        name: 'Second',
        url: 'https://mcp.example.com/mcp',
        headers: {'Authorization': 'Bearer second'},
      ),
    ];
    final incoming = AISettings.defaults();
    incoming.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://api.example.com/v1'
      ..apiKey = '';
    incoming.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Imported',
        url: 'https://mcp.example.com/mcp',
      ),
    ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(
      merged.providers.firstWhere((provider) => provider.id == 'openai').apiKey,
      isEmpty,
    );
    expect(merged.mcpServers.single.headers, isEmpty);
  });

  test('Uri 额外规范化不得把不同 raw endpoint 合并后继承 secrets', () {
    final local = AISettings.defaults();
    local.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://api.example.com/tenant/b?tenant=local'
      ..apiKey = 'local-provider-secret';
    local.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Local',
        url: 'https://mcp.example.com/tenant/b?x=%25zz',
        headers: {'Authorization': 'Bearer local-mcp-secret'},
      ),
    ];
    final incoming = AISettings.defaults();
    incoming.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://api.example.com/tenant/a/../b?%74enant=local'
      ..apiKey = '';
    incoming.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Imported',
        url: r'https://mcp.example.com/tenant\b?x=%zz',
      ),
    ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(
      merged.providers.firstWhere((provider) => provider.id == 'openai').apiKey,
      isEmpty,
    );
    expect(merged.mcpServers.single.headers, isEmpty);
  });

  test('括号 host literal 不得与同文本 DNS host 共用 secrets', () {
    final local = AISettings.defaults();
    local.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://v1.foo/v1'
      ..apiKey = 'local-provider-secret';
    local.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Local',
        url: 'https://v1.foo/mcp',
        headers: {'Authorization': 'Bearer local-mcp-secret'},
      ),
    ];
    final incoming = AISettings.defaults();
    incoming.providers.firstWhere((provider) => provider.id == 'openai')
      ..apiHost = 'https://[v1.foo]/v1'
      ..apiKey = '';
    incoming.mcpServers = const [
      McpServerConfig(
        id: 'remote',
        name: 'Imported',
        url: 'https://[v1.foo]/mcp',
      ),
    ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(
      merged.providers.firstWhere((provider) => provider.id == 'openai').apiKey,
      isEmpty,
    );
    expect(merged.mcpServers.single.headers, isEmpty);
  });

  test('备份即使携带完整 secrets 也不能授予 MCP 信任', () {
    final local = AISettings.defaults()
      ..mcpBackendEnabled = false
      ..mcpBackendTrusted = false
      ..mcpServers = const [];
    final incoming = AISettings.defaults()
      ..mcpBackendEnabled = true
      ..mcpBackendTrusted = true
      ..mcpServers = const [
        McpServerConfig(
          id: 'crafted',
          name: 'Crafted server',
          url: 'http://127.0.0.1:8080/mcp',
          enabled: true,
          trusted: true,
          permission: McpToolPermission.confirmWrite,
          headers: {},
        ),
      ];

    final merged = mergeImportedSettingsSecrets(
      incoming,
      local,
      incomingIncludesSecrets: true,
    );

    expect(merged.mcpBackendEnabled, isFalse);
    expect(merged.mcpBackendTrusted, isFalse);
    expect(merged.mcpServers.single.enabled, isFalse);
    expect(merged.mcpServers.single.trusted, isFalse);
    expect(merged.mcpServers.single.permission, McpToolPermission.readOnly);
    expect(merged.mcpServers.single.headers, isEmpty);
  });

  test('相同且唯一的 MCP endpoint 继续沿用本地已授予的信任', () {
    final local = AISettings.defaults()
      ..mcpBackendEnabled = true
      ..mcpBackendTrusted = true
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Local',
          url: 'https://MCP.EXAMPLE.com:443/mcp/',
          enabled: true,
          trusted: true,
          permission: McpToolPermission.confirmWrite,
          enabledProjectIds: [7],
        ),
      ];
    final incoming = AISettings.defaults()
      ..mcpBackendTrusted = false
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Imported',
          url: 'https://mcp.example.com/mcp',
          trusted: false,
        ),
      ];

    final merged = mergeImportedSettingsSecrets(incoming, local);

    expect(merged.mcpBackendTrusted, isTrue);
    expect(merged.mcpBackendEnabled, isTrue);
    expect(merged.mcpServers.single.enabled, isTrue);
    expect(merged.mcpServers.single.trusted, isTrue);
    expect(merged.mcpServers.single.permission, McpToolPermission.confirmWrite);
    expect(merged.mcpServers.single.enabledProjectIds, [7]);
  });

  test('MCP 改址或本地匹配歧义时不继承信任', () {
    final local = AISettings.defaults()
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Local 1',
          url: 'https://mcp.example/mcp',
          trusted: true,
        ),
        McpServerConfig(
          id: 'remote',
          name: 'Local 2',
          url: 'https://mcp.example/mcp/',
          trusted: true,
        ),
      ];
    final ambiguous = AISettings.defaults()
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Imported',
          url: 'https://mcp.example/mcp',
          trusted: true,
        ),
      ];
    final moved = AISettings.defaults()
      ..mcpServers = const [
        McpServerConfig(
          id: 'remote',
          name: 'Imported',
          url: 'https://other.example/mcp',
          trusted: true,
        ),
      ];

    expect(
      mergeImportedSettingsSecrets(ambiguous, local).mcpServers.single.trusted,
      isFalse,
    );
    expect(
      mergeImportedSettingsSecrets(moved, local).mcpServers.single.trusted,
      isFalse,
    );
  });
}
