#!/usr/bin/env python3
"""Run team HTTP/locking tests in an owned disposable PostgreSQL cluster."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    binary = os.environ.get('KNOWLEDGE_PG_BIN')
    if not binary:
        executable = shutil.which('initdb')
        if executable:
            binary = str(Path(executable).parent)
        elif Path('/opt/homebrew/opt/postgresql@16/bin/initdb').exists():
            binary = '/opt/homebrew/opt/postgresql@16/bin'
    if not binary or not Path(binary, 'pg_ctl').exists():
        raise SystemExit('Install PostgreSQL or set KNOWLEDGE_PG_BIN to its bin directory.')
    root = Path(tempfile.mkdtemp(prefix='chatai-knowledge-pg-', dir='/tmp'))
    root.chmod(0o700)
    started = False
    result = 1
    try:
        with (root / 'setup.log').open('w') as log:
            subprocess.run([str(Path(binary, 'initdb')), '-D', str(root / 'data'),
                            '-A', 'trust', '-U', 'knowledge_fixture', '--no-locale', '-E', 'UTF8'],
                           check=True, stdout=log, stderr=log, timeout=45)
            subprocess.run([str(Path(binary, 'pg_ctl')), '-D', str(root / 'data'),
                            '-l', str(root / 'postgres.log'), '-o',
                            f"-k {root} -p 55849 -c listen_addresses=''", '-w', 'start'],
                           check=True, stdout=log, stderr=log, timeout=45)
        started = True
        config = root / 'fixture.json'
        config.write_text(json.dumps({'root': str(root), 'host': str(root), 'port': 55849,
                                      'username': 'knowledge_fixture', 'database': 'postgres'}))
        config.chmod(0o600)
        env = dict(os.environ, KNOWLEDGE_PG_TEST='1', KNOWLEDGE_PG_FIXTURE=str(config),
                   JWT_SECRET='synthetic-knowledge-test-secret-not-production-000000000000')
        project = Path(__file__).resolve().parents[3]
        result = subprocess.run(['pnpm', '--filter', 'chatgpt_backend', 'exec', 'jest',
                                 'knowledge-team.postgres.spec.ts', '--runInBand'], cwd=project, env=env).returncode
    finally:
        stopped = not started
        if started:
            stopped = subprocess.run([str(Path(binary, 'pg_ctl')), '-D', str(root / 'data'),
                                      '-m', 'fast', '-w', 'stop'], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, timeout=45).returncode == 0
        if stopped:
            shutil.rmtree(root)
        else:
            print(f'Owned test cluster needs cleanup: {root}', file=sys.stderr)
            result = 1
    return result


if __name__ == '__main__':
    raise SystemExit(main())
