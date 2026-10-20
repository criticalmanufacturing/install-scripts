#!/usr/bin/env python3
"""Hermetic checks for setup-skupper-ubuntu.sh. Never provisions a host.

Requires Python 3, PyYAML, and Bash. Optionally pass --bash /path/to/bash.
Tests real embedded validators, the hosts transformation, and resource
reconciliation with a filesystem-backed Skupper double. Live Podman/systemd,
network, package installation and reboot persistence require an Ubuntu VM test.
"""
import ast
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

BASH = shutil.which('bash')
if '--bash' in sys.argv:
    i = sys.argv.index('--bash')
    BASH = sys.argv[i + 1]
    del sys.argv[i:i + 2]
SCRIPT = Path(__file__).resolve().parents[1] / 'setup-skupper-ubuntu.sh'
SOURCE = SCRIPT.read_text(encoding='utf-8')
HELPER = SOURCE.split("<<'PYHELPER'\n", 1)[1].split('\nPYHELPER', 1)[0]
HOSTS = SOURCE.split("<<'PYHOSTS'\n", 1)[1].split('\nPYHOSTS', 1)[0]

def fixture():
    enc = lambda s: base64.b64encode(s.encode()).decode()
    return [
        {'apiVersion': 'skupper.io/v2alpha1', 'kind': 'Link', 'metadata': {'name': 'cloud-link'},
         'spec': {'tlsCredentials': 'cloud-tls', 'cost': 1,
                  'endpoints': [{'host': 'skupper.example.com', 'port': '55671', 'name': 'inter-router'}]}},
        {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': 'cloud-tls'},
         'type': 'kubernetes.io/tls', 'data': {
             'ca.crt': enc('-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----'),
             'tls.crt': enc('-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----'),
             'tls.key': enc('-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----')}}]

# This double models 2.2.3's output formats and its per-object apply failure
# behavior. It is not evidence that real containers start or TLS is operational.
FAKE_CLI = r'''
import json, os, pathlib, sys, yaml
a = sys.argv[1:]
root = pathlib.Path(os.environ['FAKE_NS_DIR']) / 'input/resources'
root.mkdir(parents=True, exist_ok=True)
with open(os.environ['FAKE_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\n')
kind, op = a[:2]
if kind == 'system' and op == 'apply':
    for d in yaml.safe_load_all(pathlib.Path(a[a.index('-f') + 1]).read_text()):
        if os.environ.get('FAKE_DROP_SECRET') and d['kind'] == 'Secret':
            continue  # Deliberately exit zero after a partial failure.
        d['metadata']['namespace'] = os.environ['FAKE_NAMESPACE']
        (root / (d['kind'].lower() + '-' + d['metadata']['name'] + '.yaml')).write_text(yaml.safe_dump(d))
elif kind == 'site' and op == 'create':
    p = root / ('site-' + a[2] + '.yaml')
    assert not p.exists(), 'must not create existing site again'
    p.write_text(yaml.safe_dump({'kind': 'Site', 'apiVersion': 'skupper.io/v2alpha1',
                                'metadata': {'name': a[2], 'namespace': os.environ['FAKE_NAMESPACE']}}))
elif kind == 'connector' and op == 'generate':
    print(yaml.safe_dump({'kind': 'Connector', 'apiVersion': 'skupper.io/v2alpha1',
                         'metadata': {'name': a[2], 'namespace': os.environ['FAKE_NAMESPACE']},
                         'spec': {'host': a[a.index('--host')+1], 'port': int(a[3]),
                                  'routingKey': a[a.index('--routing-key')+1], 'type': 'tcp'}}))
elif op == 'status':
    p = root / (kind + '-' + a[2] + '.yaml')
    if not p.exists():
        sys.exit(1)
    d = yaml.safe_load(p.read_text())
    d['status'] = {'status': 'Ready', 'conditions': [{'type': 'Configured', 'status': 'True'}]}
    print(json.dumps(d) if '-o' in a else d['metadata']['name'])
else:
    raise RuntimeError('Unexpected fake command: ' + repr(a))
'''

class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='skupper-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.link = self.root / 'link.yaml'
        self.write_link(fixture())

    def write_link(self, docs):
        self.link.write_text(yaml.safe_dump_all(docs), encoding='utf-8')
        self.link.chmod(0o600)

    def helper(self, *args, ok=True):
        r = subprocess.run([sys.executable, '-c', HELPER, *map(str, args)], text=True, capture_output=True)
        self.assertEqual(r.returncode == 0, ok, r.stderr)
        return r

    def shell(self, code, env=None, ok=True):
        e = os.environ.copy()
        e.update(SETUP_SCRIPT=SCRIPT.as_posix(), PYTHON_RUNNER=Path(sys.executable).as_posix())
        if env:
            e.update({k: str(v) for k, v in env.items()})
        prelude = 'export PATH="/usr/bin:/bin:$PATH"\nsource "$SETUP_SCRIPT"\npython3() { "$PYTHON_RUNNER" "$@"; }\n'
        r = subprocess.run([BASH, '--noprofile', '--norc', '-c', prelude + code], env=e, text=True, capture_output=True, timeout=40)
        self.assertEqual(r.returncode == 0, ok, r.stderr + r.stdout)
        return r

    def test_bash_syntax(self):
        # Stdin avoids drive-letter argument quirks in Git Bash on Windows.
        r = subprocess.run([BASH, '--noprofile', '--norc', '-n'], input=SOURCE, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_embedded_python_syntax(self):
        compile(HELPER, 'embedded-validator', 'exec')
        compile(HOSTS, 'embedded-hosts', 'exec')

    def test_required_arguments(self):
        self.shell('parse_args --cloud-host example.com', ok=False)
        self.shell('parse_args --app-port', ok=False)
        self.shell('parse_args --unknown', ok=False)
        self.shell('parse_args --link-file fake --cloud-host skupper.example.com '
                   '--cloud-ip 198.51.100.10 --app-ip 192.0.2.10 --app-port 12345', ok=False)

    def test_supported_ubuntu_releases(self):
        release = self.root / 'os-release'
        script = self.root / 'os-gate.sh'
        script.write_text(SOURCE.replace('/etc/os-release', str(release)))
        for distro, version, supported in [('ubuntu', '24.04', True), ('ubuntu', '26.04', True),
                                           ('ubuntu', '22.04', False), ('ubuntu', '25.10', False),
                                           ('ubuntu', '28.04', False), ('debian', '13', False)]:
            with self.subTest(distro=distro, version=version):
                release.write_text(f'ID={distro}\nVERSION_ID={version}\n')
                r = subprocess.run([BASH, '-c', 'source "$1"; check_ubuntu', 'test', str(script)],
                                   capture_output=True, text=True)
                self.assertEqual(r.returncode == 0, supported, r.stderr)

    def test_powershell_bom_and_crlf_link(self):
        self.link.write_bytes(b'\xef\xbb\xbf' + self.link.read_bytes().replace(b'\n', b'\r\n'))
        self.helper('link', self.link, 'skupper.example.com', '198.51.100.10')

    def test_ports_and_timeout(self):
        base = 'parse_args --link-file fake --cloud-host skupper.example.com --cloud-ip 198.51.100.10 --app-ip 192.0.2.10 --routing-key application --app-port '
        for bad in ['0', '65536', '-1', '1x', '999999999999999999999']:
            with self.subTest(port=bad):
                self.shell(base + bad, ok=False)
        self.assertEqual(self.shell(base + '07990; printf "%s" "$APP_PORT"').stdout, '7990')
        self.shell(base + '7990 --timeout 0', ok=False)

    def test_ip_and_hostname_validation(self):
        self.helper('inputs', 'skupper.example.com', '198.51.100.10', '192.0.2.10')
        self.helper('inputs', 'skupper.example.com', '2001:db8::10', '::1')
        for host, ip, app in [('bad;host', '198.51.100.10', '10.0.0.1'), ('good.example', '999.1.1.1', '10.0.0.1'),
                              ('good.example', '0.0.0.0', '10.0.0.1'), ('good.example', '198.51.100.10', '224.0.0.1')]:
            self.helper('inputs', host, ip, app, ok=False)

    def test_valid_link_bundle(self):
        r = self.helper('link', self.link, 'skupper.example.com', '198.51.100.10')
        self.assertEqual(r.stdout, 'cloud-link 55671\n')

    def test_reject_wrong_endpoint_host(self):
        self.helper('link', self.link, 'different.example.com', '198.51.100.10', ok=False)

    def test_reject_unquoted_endpoint_port(self):
        docs = fixture()
        docs[0]['spec']['endpoints'][0]['port'] = 55671
        self.write_link(docs)
        self.helper('link', self.link, 'skupper.example.com', '198.51.100.10', ok=False)

    def test_reject_unsafe_resource_names(self):
        for name in ['../outside', 'Bad_Name', 'x' * 64, '-bad']:
            docs = fixture()
            docs[0]['metadata']['name'] = name
            self.write_link(docs)
            self.helper('link', self.link, 'skupper.example.com', '198.51.100.10', ok=False)

    def test_reject_unrelated_resources_and_tokens(self):
        for kind in ['Site', 'AccessToken', 'Connector']:
            docs = fixture()
            docs.append({'apiVersion': 'skupper.io/v2alpha1', 'kind': kind, 'metadata': {'name': 'surprise'}})
            self.write_link(docs)
            self.helper('link', self.link, 'skupper.example.com', '198.51.100.10', ok=False)

    def test_reject_duplicate_keys_aliases_and_resources(self):
        original = self.link.read_text()
        for text in ['kind: Link\nkind: Secret\n', 'x: &key value\ny: *key\n', original + '\n---\n' + original]:
            self.link.write_text(text)
            self.helper('link', self.link, 'skupper.example.com', '198.51.100.10', ok=False)

    def test_reject_missing_or_invalid_secret_without_leaking(self):
        docs = fixture()
        self.write_link(docs[:1])
        self.helper('link', self.link, 'skupper.example.com', '198.51.100.10', ok=False)
        docs[1]['data']['tls.key'] = 'DO-NOT-PRINT-THIS-SECRET'
        self.write_link(docs)
        r = self.helper('link', self.link, 'skupper.example.com', '198.51.100.10', ok=False)
        self.assertNotIn('DO-NOT-PRINT', r.stderr)

    def test_hosts_alias_preservation_duplicates_and_idempotence(self):
        tree = ast.parse(HOSTS)
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'transform')
        ctx = {'host': 'skupper.example.com', 'ip': '198.51.100.10'}
        exec(compile(ast.Module(body=[fn], type_ignores=[]), 'hosts-transform', 'exec'), ctx)
        before = ('127.0.0.1 localhost\n10.0.0.1 skupper.example.com keep-alias # preserve this\n'
                  '10.0.0.2 SKUPPER.EXAMPLE.COM\n# untouched\n')
        after = ctx['transform'](before)
        self.assertIn('10.0.0.1\tkeep-alias # preserve this', after)
        self.assertIn('127.0.0.1 localhost', after)
        self.assertEqual(after.count('skupper.example.com'), 1)
        self.assertEqual(ctx['transform'](after), after)

    def test_router_hosts_ipv6_equivalence_and_conflicts(self):
        p = self.root / 'hosts'
        p.write_text('2001:db8:0:0:0:0:0:10 skupper.example.com\n')
        self.helper('router-hosts', p, 'skupper.example.com', '2001:db8::10')
        p.write_text(p.read_text() + '10.0.0.1 skupper.example.com\n')
        self.helper('router-hosts', p, 'skupper.example.com', '2001:db8::10', ok=False)

    def test_controller_policy(self):
        p = self.root / 'controller.json'
        obj = [{'Config': {'Image': 'quay.io/skupper/system-controller:2.2.3', 'Env': ['SKUPPER_SYSTEM_RELOAD_TYPE=auto']}}]
        p.write_text(json.dumps(obj))
        self.helper('inspect-controller', p)
        obj[0]['Config']['Env'] = ['SKUPPER_SYSTEM_RELOAD_TYPE=manual']
        p.write_text(json.dumps(obj))
        self.helper('inspect-controller', p, ok=False)

    @unittest.skipUnless(os.name == 'posix', 'Unix ownership/O_NOFOLLOW checks require a Unix filesystem')
    def test_secure_snapshot(self):
        dest = self.root / 'copy.yaml'
        # The validator must create private files even under a permissive caller.
        r = subprocess.run([sys.executable, '-c',
                            'import os; os.umask(0); exec(' + repr(HELPER) + ')',
                            'snapshot', str(self.link), str(dest)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(dest.stat().st_mode & 0o077, 0)
        self.link.chmod(0o644)
        self.helper('snapshot', self.link, self.root / 'insecure.yaml', ok=False)
        symlink = self.root / 'symlink.yaml'
        symlink.symlink_to(self.link)
        self.helper('snapshot', symlink, self.root / 'symlink-copy.yaml', ok=False)

    def reconcile(self, app_port='7990', drop_secret=False, ok=True):
        fake = self.root / 'fake_skupper.py'
        fake.write_text(FAKE_CLI)
        ns = self.root / 'ns'
        env = {'WORK_DIR': self.root.as_posix(), 'NS_DIR': ns.as_posix(), 'NAMESPACE': 'customer-a',
               'SITE_NAME': 'customer-a', 'APP_IP': '192.0.2.10', 'APP_PORT': app_port,
               'CONNECTOR_NAME': 'application', 'ROUTING_KEY': 'sap', 'TIMEOUT': '10',
               'FAKE_NS_DIR': ns.as_posix(), 'FAKE_NAMESPACE': 'customer-a',
               'FAKE_LOG': (self.root / 'calls.jsonl').as_posix(), 'FAKE_CLI': fake.as_posix(),
               'FAKE_DROP_SECRET': '1' if drop_secret else ''}
        # Sourcing initializes globals; restore fixture-specific values afterward.
        assigns = '\n'.join(k + '="${TEST_' + k + '}"' for k in ['WORK_DIR', 'NS_DIR', 'NAMESPACE', 'SITE_NAME', 'APP_IP', 'APP_PORT', 'CONNECTOR_NAME', 'ROUTING_KEY', 'TIMEOUT'])
        env.update({'TEST_' + k: v for k, v in env.copy().items()})
        (self.root / 'endpoints.txt').write_text('cloud-link 55671\n')
        ns.mkdir(exist_ok=True)
        code = assigns + '''
sk() { "$PYTHON_RUNNER" "$FAKE_CLI" "$@"; }
refresh_router_hosts() { :; } # Runtime container refresh is a live-VM test.
apply_resources
'''
        return self.shell(code, env, ok=ok)

    def test_first_run_rerun_and_target_update(self):
        self.reconcile()
        log = self.root / 'calls.jsonl'
        first = [json.loads(x) for x in log.read_text().splitlines()]
        self.assertEqual(sum(x[:2] == ['site', 'create'] for x in first), 1)
        self.assertEqual(sum(x[:2] == ['system', 'apply'] for x in first), 2)
        log.write_text('')
        self.reconcile()
        second = [json.loads(x) for x in log.read_text().splitlines()]
        self.assertFalse(any(x[:2] in [['site', 'create'], ['system', 'apply']] for x in second))
        log.write_text('')
        self.reconcile(app_port='8000')
        third = [json.loads(x) for x in log.read_text().splitlines()]
        self.assertEqual(sum(x[:2] == ['system', 'apply'] for x in third), 1)

    def test_partial_apply_zero_exit_is_rejected(self):
        self.reconcile(drop_secret=True, ok=False)

    def test_conflicting_namespace_owner_is_rejected(self):
        ns = self.root / 'ns'
        ns.mkdir()
        (ns / '.ubuntu-setup-site').write_text('other-site\n')
        self.reconcile(ok=False)

    def test_unowned_namespace_with_credentials_is_rejected(self):
        resources = self.root / 'ns' / 'input' / 'resources'
        resources.mkdir(parents=True)
        (resources / 'secret-existing.yaml').write_text('kind: Secret\n')
        self.reconcile(ok=False)

    def test_dry_run_has_no_mutation_calls(self):
        env = {'TEST_LINK': self.link.as_posix()}
        code = '''
check_ubuntu() { :; }
check_user() { :; }
check_session() { :; }
check_subids() { :; }
check_link_permissions() { :; } # Unix file permissions tested separately.
set_names() { SITE_NAME=customer-a; NAMESPACE=customer-a; ROUTING_KEY=application; }
sudo() { echo UNEXPECTED-SUDO >&2; return 99; }
install_packages() { echo UNEXPECTED-INSTALL >&2; return 99; }
main --dry-run --link-file "$TEST_LINK" --cloud-host skupper.example.com --cloud-ip 198.51.100.10 --app-ip 192.0.2.10 --app-port 7990 --routing-key application
'''
        r = self.shell(code, env)
        self.assertIn('DRY RUN', r.stderr)
        self.assertNotIn('UNEXPECTED', r.stderr)

    def test_os_gate_precedes_arguments(self):
        r = self.shell('check_ubuntu() { die OS-GATE; }; parse_args() { echo ARGUMENTS-RAN; }; main --help', ok=False)
        self.assertIn('OS-GATE', r.stderr)
        self.assertNotIn('ARGUMENTS-RAN', r.stdout)

if __name__ == '__main__':
    if not BASH:
        raise SystemExit('Bash is required; pass --bash /path/to/bash.')
    unittest.main(verbosity=2)
