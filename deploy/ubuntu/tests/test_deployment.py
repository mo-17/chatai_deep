"""无 root / 网络副作用的部署数据合同测试。"""
import importlib.util
import json
from pathlib import Path
import platform
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load('config')
package = load('package')


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def generate(self):
        destination = self.root / 'backend.env'
        config.generate(SCRIPTS / 'backend.env.example', destination)
        return destination

    def test_fresh_secrets_and_permissions_and_no_rotation(self):
        destination = self.generate()
        values = config.validate(destination)
        keys = [values[key] for key in ['DB_PASSWORD', 'JWT_SECRET', 'APP_SECRET_KEY', 'ADMIN_DEFAULT_PASSWORD']]
        self.assertEqual(len(set(keys)), 4)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        before = destination.read_bytes()
        with self.assertRaises(FileExistsError):
            config.generate(SCRIPTS / 'backend.env.example', destination)
        self.assertEqual(destination.read_bytes(), before)

    def test_rejects_public_binding_auto_schema_and_duplicate_keys(self):
        original = self.generate().read_text()
        for old, new in [('HOST=127.0.0.1', 'HOST=0.0.0.0'),
                         ('DB_SYNCHRONIZE=false', 'DB_SYNCHRONIZE=true'),
                         ('DB_POOL_MAX=3', 'DB_POOL_MAX=30')]:
            with self.subTest(new=new):
                path = self.root / 'invalid.env'
                path.write_text(original.replace(old, new))
                with self.assertRaises(ValueError):
                    config.validate(path)
        path.write_text(original + '\nHOST=0.0.0.0\n')
        with self.assertRaises(ValueError):
            config.validate(path)

    def test_config_is_read_as_data_without_executing_shell(self):
        destination = self.generate()
        sentinel = self.root / 'must-not-exist'
        with destination.open('a') as output:
            output.write(f'\nEXTRA="$(touch {sentinel})"\n')
        self.assertIn('$(touch ', config.read_config(destination)['EXTRA'])
        self.assertFalse(sentinel.exists())

    def fixture_source(self):
        source = self.root / 'source'
        for name in package.REQUIRED:
            path = source / name
            if name == '.npmrc' or name.endswith(('.json', '.yaml', '.ts', '.mjs')):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('{}')
            else:
                path.mkdir(parents=True, exist_ok=True)
        (source / '.npmrc').write_text('public-hoist-pattern[]=*@heroui/*\n')
        (source / 'chatgpt_backend/src/main.ts').write_text('export {};')
        (source / 'chatgpt_backend/src/test').mkdir()
        (source / 'chatgpt_backend/src/test/test.module.ts').write_text('export {};')
        return source

    def test_source_package_excludes_local_data_and_keeps_build_inputs(self):
        source = self.fixture_source()
        for name in ['chatgpt_backend/.env', 'chatgpt_backend/libs/auth/.env.private',
                     'deploy/ubuntu/backend.env', 'deploy/ubuntu/backend.env.production',
                     'chatgpt_backend/libs/auth/secrets/apple.p8',
                     'chatgpt_admin/src/test/private.test.ts',
                     'chatgpt_backend/src/secret.spec.ts',
                     'chatgpt_admin/node_modules/local.txt',
                     'chatgpt_admin/.next/local.txt', 'deploy/ubuntu/tests/local.txt']:
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('MUST_NOT_SHIP')
        archive = self.root / 'source.tgz'
        package.package(source, archive)
        with tarfile.open(archive) as tar:
            self.assertIn('chatgpt_backend/src/main.ts', tar.getnames())
            self.assertIn('chatgpt_backend/src/test/test.module.ts', tar.getnames())
            self.assertIn('chatgpt_admin/hero.ts', tar.getnames())
            self.assertIn('chatgpt_admin/next.config.ts', tar.getnames())
            self.assertEqual(tar.extractfile('.npmrc').read(), b'public-hoist-pattern[]=*@heroui/*\n')
            for info in tar:
                if info.isfile():
                    self.assertNotIn(b'MUST_NOT_SHIP', tar.extractfile(info).read())
                self.assertEqual(info.mode & 0o077, 0o055 if info.isdir() else 0o044)
        with self.assertRaises(ValueError):
            package.package(source, archive)
        with self.assertRaises(ValueError):
            package.package(source, source / 'recursive.tgz')

    def test_source_symlink_cannot_include_outside_secrets(self):
        source = self.fixture_source()
        (source / 'chatgpt_backend/src/private-link').symlink_to('/etc/passwd')
        archive = self.root / 'rejected.tgz'
        with self.assertRaises(ValueError):
            package.package(source, archive)
        self.assertFalse(archive.exists())

    def fixture_release(self):
        release = self.root / 'release'
        release.mkdir()
        manifest = {'format': 1, 'platform': 'linux', 'arch': platform.machine(),
                    'nodeMajor': 22, 'backend': 'http://127.0.0.1:3000'}
        (release / 'ubuntu-release.json').write_text(json.dumps(manifest))
        for name in ['chatgpt_backend/dist/src/main.js',
                     'chatgpt_backend/dist/src/database/migration-main.js',
                     'chatgpt_backend/node_modules/pg/package.json',
                     'chatgpt_admin/.next/BUILD_ID',
                     'chatgpt_admin/node_modules/next/dist/bin/next']:
            path = release / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        css = release / 'chatgpt_admin/.next/static/css/main.css'
        css.parent.mkdir(parents=True)
        css.write_text(r'.h-10{height:2.5rem}.min-w-20{min-width:5rem}'
                       r'.text-primary-foreground{color:white}'
                       r'.group-data-\[filled-within\=true\]\:top-0{top:0}')
        return release, manifest

    def test_prepared_release_rejects_css_without_component_library_styles(self):
        release, _ = self.fixture_release()
        css = release / 'chatgpt_admin/.next/static/css/main.css'
        css.write_text('.flex{display:flex}.h-14{height:3.5rem}')
        with self.assertRaisesRegex(ValueError, '后台组件样式缺失'):
            package.verify_release(release)

    def test_style_source_check_rejects_missing_or_empty_hoisted_theme(self):
        with self.assertRaisesRegex(ValueError, 'HeroUI 样式源不存在'):
            package.verify_admin_style_source(self.root)
        source = self.root / 'node_modules/@heroui/theme/dist'
        source.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'HeroUI 样式源不存在'):
            package.verify_admin_style_source(self.root)
        (source / 'index.js').write_text('export {};')
        package.verify_admin_style_source(self.root)

    def test_prepared_release_rejects_wrong_arch_and_missing_migration(self):
        release, manifest = self.fixture_release()
        package.verify_release(release)
        manifest['arch'] = 'different-cpu'
        (release / 'ubuntu-release.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'arch'):
            package.verify_release(release)
        manifest['arch'] = platform.machine()
        (release / 'ubuntu-release.json').write_text(json.dumps(manifest))
        (release / 'chatgpt_backend/dist/src/database/migration-main.js').unlink()
        with self.assertRaisesRegex(ValueError, 'migration-main'):
            package.verify_release(release)

    def test_prepared_release_rejects_secrets_and_external_dependency_links(self):
        release, _ = self.fixture_release()
        secret = release / 'chatgpt_admin/.env.local'
        secret.write_text('API_KEY=secret')
        with self.assertRaisesRegex(ValueError, '环境文件'):
            package.verify_release(release)
        secret.unlink()
        (release / 'chatgpt_admin/node_modules/external').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, '外部链接'):
            package.verify_release(release)

    def test_scripts_fail_safely_on_non_linux_before_server_mutations(self):
        if platform.system() == 'Linux':
            self.skipTest('此检查针对非 Linux 开发机')
        command = ['bash', str(SCRIPTS / 'build.sh'), str(self.root), str(self.root / 'build')]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Linux', result.stderr)
        self.assertFalse((self.root / 'build').exists())

    def run_deploy_fixture(self, fail_stage=''):
        # 运行真实 deploy.sh 的控制流程，只替换系统路径和有系统副作用的命令。
        # 不模拟迁移数据库本身；验证迁移或备份失败时不会激活 / 启动新版本。
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ['package.py', 'config.py', 'chatai-deep-api.service',
                     'chatai-deep-admin.service', 'nginx.conf']:
            shutil.copy(SCRIPTS / name, scripts / name)
        app = self.root / 'app'
        (app / 'releases').mkdir(parents=True)
        old = app / 'old'
        old.mkdir()
        (app / 'current').symlink_to(old)
        config_dir = self.root / 'config'
        config_dir.mkdir()
        config.generate(SCRIPTS / 'backend.env.example', config_dir / 'backend.env')
        (self.root / 'units').mkdir()
        (self.root / 'nginx').mkdir()
        binaries = self.root / 'bin'
        binaries.mkdir()
        events = self.root / 'events'
        common = f'''set -Eeuo pipefail
APP_ROOT='{app}'
CONFIG_ROOT='{config_dir}'
CACHE_ROOT='{self.root / 'cache'}'
APP_USER=fixture
NODE_HOME='{self.root / 'node'}'
SCRIPT_DIR='{scripts}'
PATH='{binaries}':$PATH
log() {{ :; }}
die() {{ echo "$*" >&2; exit 1; }}
require_root() {{ :; }}
require_ubuntu() {{ :; }}
require_ready() {{ :; }}
health() {{ echo "health $1" >> "$EVENTS"; }}
'''
        (scripts / 'common.sh').write_text(common)
        (scripts / 'backup.sh').write_text('echo backup >> "$EVENTS"\n[[ $FAIL_STAGE != backup ]]\n')
        deploy = (SCRIPTS / 'deploy.sh').read_text()
        for original, replacement in [('/run/lock/chatai-deep-deploy.lock', str(self.root / 'lock')),
                                      ('/etc/systemd/system', str(self.root / 'units')),
                                      ('/etc/nginx/conf.d', str(self.root / 'nginx'))]:
            deploy = deploy.replace(original, replacement)
        (scripts / 'deploy.sh').write_text(deploy)
        commands = {
            'flock': ':',
            'chown': ':',
            'systemctl': 'echo "systemctl $*" >> "$EVENTS"',
            'systemd-run': 'echo migrate >> "$EVENTS"; [[ $FAIL_STAGE != migration ]]',
            'nginx': 'echo nginx-check >> "$EVENTS"',
            'install': '''python3 - "$@" <<'PY'
import pathlib, shutil, sys
a = sys.argv[1:]
if '-d' in a:
    pathlib.Path(a[-1]).mkdir(parents=True, exist_ok=True)
else:
    shutil.copyfile(a[-2], a[-1])
PY''',
            'mv': '''python3 - "$@" <<'PY'
import os, sys
os.replace(sys.argv[-2], sys.argv[-1])
PY''',
        }
        for name, body in commands.items():
            command = binaries / name
            command.write_text('#!/usr/bin/env bash\nset -e\n' + body + '\n')
            command.chmod(0o755)
        prepared, _ = self.fixture_release()
        env = dict(os.environ, EVENTS=str(events), FAIL_STAGE=fail_stage)
        result = subprocess.run(['bash', str(scripts / 'deploy.sh'), '--prepared', str(prepared)],
                                env=env, text=True, capture_output=True)
        return result, events.read_text().splitlines(), app, old

    def test_failed_migration_keeps_old_release_and_never_starts_new_services(self):
        result, events, app, old = self.run_deploy_fixture('migration')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((app / 'current').resolve(), old.resolve())
        self.assertIn('backup', events)
        self.assertIn('migrate', events)
        self.assertFalse(any(event.startswith('systemctl start') for event in events))

    def test_failed_backup_prevents_migration_and_activation(self):
        result, events, app, old = self.run_deploy_fixture('backup')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('migrate', events)
        self.assertEqual((app / 'current').resolve(), old.resolve())
        self.assertFalse(any(event.startswith('systemctl start') for event in events))

    def test_success_starts_services_only_after_backup_and_migration(self):
        result, events, app, old = self.run_deploy_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual((app / 'current').resolve(), old.resolve())
        start = events.index('systemctl start chatai-deep-api')
        self.assertLess(events.index('backup'), events.index('migrate'))
        self.assertLess(events.index('migrate'), start)
        self.assertIn('health http://127.0.0.1:8080/healthz', events)


if __name__ == '__main__':
    unittest.main()
