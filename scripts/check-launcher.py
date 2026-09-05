#!/usr/bin/env python3
"""Exercise launcher environment/argv contracts on the host, not iOS execution.

RootHide's jbroot command and final exec path are simulated. Device package
installation and runs from both zsh and fish are still required.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def check(template):
    source = template.read_text()
    program = template.name.removesuffix('.launcher.sh')
    with tempfile.TemporaryDirectory(prefix='launcher-check-') as work:
        work = Path(work)
        bootstrap = work / 'bootstrap with spaces'
        commands = work / 'commands'
        commands.mkdir()
        for directory in ['bin', 'usr/bin', 'etc/ssl']:
            (bootstrap / directory).mkdir(parents=True)
        for binary in ['bin/sh', 'bin/zsh', 'usr/bin/uiopen']:
            (bootstrap / binary).symlink_to('/bin/sh')
        (bootstrap / 'etc/ssl/cert.pem').write_text('fixture CA\n')
        jbroot = commands / 'jbroot'
        jbroot.write_text('#!/bin/sh\n[ "${TEST_JBROOT_FAIL:-0}" = 0 ] || exit 7\nprintf "%s\\n" "$TEST_BOOTSTRAP"\n')
        jbroot.chmod(0o755)
        payload = work / 'payload'
        payload.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                           'print(json.dumps({"argv": sys.argv[1:], "env": dict(os.environ)}))\n'
                           'sys.exit(23)\n')
        payload.chmod(0o755)
        arguments = ['--version', 'two words', '', '*', '$HOME', 'quote"and\'']
        cases = 0
        for flavor in ['rootless', 'roothide']:
            prefix = str(bootstrap) if flavor == 'rootless' else ''
            rendered = source.replace('@PREFIX@', prefix)
            assert rendered.splitlines()[0] == '#!' + prefix + '/bin/sh'
            # Simulate only vroot's final pathname mapping. Everything else is
            # the actual shipped launcher, including shell conditionals.
            original_exec = f'exec {prefix}/usr/libexec/{program}/{program} "$@"'
            assert original_exec in rendered
            rendered = rendered.replace(original_exec, f'exec {shlex.quote(str(payload))} "$@"')
            launcher = work / ('launcher-' + flavor)
            launcher.write_text(rendered)
            subprocess.run(['/bin/sh', '-n', str(launcher)], check=True)
            for shell in ['/bin/zsh', str(bootstrap / 'bin/zsh'), '/custom/bin/fish', '']:
                for overrides in [False, True]:
                    env = {'PATH': str(commands) + ':/usr/bin:/bin', 'HOME': str(work),
                           'TEST_BOOTSTRAP': str(bootstrap), 'SHELL': shell}
                    if overrides:
                        env.update(SSL_CERT_FILE='/custom/ca.pem', BROWSER='/custom/browser')
                    result = subprocess.run(['/bin/sh', str(launcher), *arguments],
                                            env=env, capture_output=True, text=True)
                    assert result.returncode == 23, (flavor, result.stderr)
                    observed = json.loads(result.stdout)
                    assert observed['argv'] == arguments
                    exported = observed['env']
                    assert exported['PATH'].split(':')[:5] == [
                        str(bootstrap / item) for item in ['usr/local/bin', 'usr/bin', 'bin', 'usr/sbin', 'sbin']]
                    assert exported['PATH'].endswith(env['PATH'])
                    if shell == '/bin/zsh':
                        assert exported['SHELL'] == str(bootstrap / 'bin/zsh')
                    elif shell:
                        assert exported['SHELL'] == shell
                    else:
                        assert exported['SHELL'].startswith(str(bootstrap) + '/')
                    if overrides:
                        assert exported['SSL_CERT_FILE'] == '/custom/ca.pem'
                        assert exported['BROWSER'] == '/custom/browser'
                    elif flavor == 'rootless':
                        assert exported['SSL_CERT_FILE'] == str(bootstrap / 'etc/ssl/cert.pem')
                        assert exported['BROWSER'] == str(bootstrap / 'usr/bin/uiopen')
                    if program == 'claude':
                        assert exported['DISABLE_AUTOUPDATER'] == '1'
                        assert exported['BUN_JSC_useJIT'] == 'false'
                    cases += 1
            if flavor == 'roothide':
                for failure in [{'TEST_JBROOT_FAIL': '1'}, {'TEST_BOOTSTRAP': ''}, {'TEST_BOOTSTRAP': 'relative'}]:
                    env = {'PATH': str(commands) + ':/usr/bin:/bin', 'TEST_BOOTSTRAP': str(bootstrap), **failure}
                    result = subprocess.run(['/bin/sh', str(launcher), '--version'],
                                            env=env, capture_output=True, text=True)
                    assert result.returncode == 127 and not result.stdout and result.stderr
                    cases += 1
            if program == 'claude':
                for action in ['install', 'update', 'upgrade']:
                    result = subprocess.run(['/bin/sh', str(launcher), action],
                                            env={'PATH': '/usr/bin:/bin'}, capture_output=True, text=True)
                    assert result.returncode == 1 and 'package-managed' in result.stderr
                    cases += 1
        print(f'{program}: {cases} launcher cases passed (host simulation)')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: check-launcher.py <launcher-template>')
    check(Path(sys.argv[1]))
