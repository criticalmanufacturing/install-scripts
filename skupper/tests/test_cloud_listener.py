"""Hermetic cloud installer checks. No kubeconfig, network, or real cluster is used."""
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import yaml

SCRIPT = Path(__file__).resolve().parents[1] / 'setup-skupper-cloud-listener.sh'


def module():
    source = SCRIPT.read_text().split("<<'PYTHON'\n", 1)[1].rsplit('\nPYTHON', 1)[0]
    source = source.rsplit('\ntry:\n    main()', 1)[0]
    result = types.ModuleType('cloud_listener')
    exec(compile(source, str(SCRIPT), 'exec'), result.__dict__)
    return result


class Cluster:
    def __init__(self):
        self.items = {}
        self.writes = []
        self.commands = []
        self.version = '2.2.3'
        self.deployment = {'metadata': {'name': 'skupper-controller', 'namespace': 'cloud'},
                           'spec': {'template': {'spec': {'containers': [{'image': 'quay.io/skupper/controller:2.2.3',
                                    'env': [{'name': 'WATCH_NAMESPACE', 'value': 'cloud'}]}]}}}}
        self.items['configmap', 'skupper'] = {'data': {'controller': 'skupper-controller'}}
        self.items['namespace', 'cloud'] = {'metadata': {'name': 'cloud'}}
        fields = {'sites': ('linkAccess', 'ha'), 'listeners': ('routingKey', 'port', 'host'),
                  'routeraccesses': ('accessType', 'roles', 'tlsCredentials'),
                  'certificates': ('ca', 'hosts', 'client', 'server'), 'links': ('endpoints', 'tlsCredentials')}
        for name, props in fields.items():
            self.items['crd', name + '.skupper.io'] = {'status': {'conditions': [{'type': 'Established', 'status': 'True'}]}, 'spec': {'versions': [{'name': 'v2alpha1', 'served': True,
                'schema': {'openAPIV3Schema': {'properties': {'spec': {'properties': dict.fromkeys(props, {})}}}}}]}}
        self.items['crd', 'ingressroutetcps.traefik.io'] = {'spec': {'versions': [{'name': 'v1alpha1', 'served': True}]}}

    def run(self, command, *, data=None, **kwargs):
        self.commands.append(command)
        if command[0] == 'helm':
            if 'version' in command:
                return 'v3.19.0'
            if 'install' in command:
                self.deployment = copy.deepcopy(Cluster().deployment)
                self.items['configmap', 'skupper'] = {'data': {'controller': 'skupper-controller'}}
                return ''
        if command[:2] == ['skupper', 'version']:
            return self.version + '\n'
        if command[0] == 'skupper':
            name = command[command.index('--tls-credentials') + 1]
            secret = self.items['secret', name]
            return yaml.safe_dump_all([{'apiVersion': 'skupper.io/v2alpha1', 'kind': 'Link',
                'metadata': {'name': 'link-cloud-'}, 'spec': {'tlsCredentials': name, 'cost': 1,
                'endpoints': [{'name': 'inter-router', 'host': 'skupper-traefik.cloud', 'port': '55671'}]}}, secret])
        if 'auth' in command:
            return 'yes\n'
        if 'rollout' in command:
            return ''
        if 'get' in command:
            parts = command[command.index('get') + 1:]
            kind = parts[0]
            if kind == 'deployments':
                return json.dumps({'items': [self.deployment] if self.deployment else []})
            if len(parts) > 1 and not parts[1].startswith('-'):
                item = self.items.get((kind, parts[1]))
                return json.dumps(item) if item else ''
            return json.dumps({'items': [v for (k, n), v in self.items.items() if k == kind]})
        if 'apply' in command:
            item = json.loads(data)
            names = {'Site': 'sites.skupper.io', 'Certificate': 'certificates.skupper.io',
                     'RouterAccess': 'routeraccesses.skupper.io', 'Listener': 'listeners.skupper.io',
                     'IngressRouteTCP': 'ingressroutetcps.traefik.io'}
            kind, name = names[item['kind']], item['metadata']['name']
            self.writes.append((kind, name))
            item['status'] = {'endpoints': [{'name': 'inter-router', 'host': 'skupper-traefik.cloud', 'port': '55671'}], 'controller': {'version': '2.2.3'}, 'conditions': [
                {'type': c, 'status': 'True', 'observedGeneration': 1} for c in ('Ready', 'Configured')]}
            item['metadata']['generation'] = 1
            self.items[kind, name] = item
            if item['kind'] == 'Certificate' and item['spec'].get('client'):
                self.items['secret', name] = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': name},
                    'type': 'kubernetes.io/tls', 'data': {'tls.crt': 'Y2VydA==', 'tls.key': 'a2V5', 'ca.crt': 'Y2E='}}
            return ''
        raise AssertionError(command)


class CloudListenerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'customer.yaml'
        self.mod = module()
        self.cluster = Cluster()
        self.argv = ['script', '--context', 'test-context', '--namespace', 'cloud', '--listener-name', 'backend',
                     '--listener-port', '7990', '--routing-key', 'customer-backend', '--cloud-host', 'router.example.test',
                     '--client-id', 'customer-01', '--link-output', str(self.output)]

    def execute(self, *extra):
        with patch.object(sys, 'argv', self.argv + list(extra)), patch.object(self.mod, 'run', self.cluster.run), \
             patch.object(self.mod.shutil, 'which', return_value='/mock/tool'), patch('sys.stdout', new_callable=io.StringIO):
            self.mod.main()

    def test_secure_export_rewrites_only_link_and_is_idempotent(self):
        self.execute()
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        contents = self.output.read_bytes()
        link, secret = list(yaml.safe_load_all(contents))
        self.assertEqual(link['spec']['endpoints'], [{'name': 'inter-router', 'host': 'router.example.test', 'port': '443'}])
        self.assertEqual(secret['metadata']['name'], 'client-customer-01')
        self.assertNotIn('namespace', link['metadata'])
        # Matching connector is deliberately absent during cloud bootstrap.
        self.execute()
        self.assertEqual(self.output.read_bytes(), contents)

    def test_wrong_cli_version_fails_before_mutation(self):
        self.cluster.version = '2.1.4'
        with self.assertRaisesRegex(RuntimeError, 'CLI 2.2.3'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_bad_port_and_hostname_rejected_before_cluster_access(self):
        for flag, value in [('--listener-port', '0'), ('--cloud-host', '192.0.2.1'), ('--cloud-host', 'x`bad.test')]:
            with self.subTest(flag=flag, value=value), self.assertRaises(RuntimeError):
                self.execute(flag, value)
        self.assertFalse(self.cluster.writes)

    def test_unmanaged_site_is_not_adopted(self):
        self.cluster.items['sites.skupper.io', 'cloud'] = {'metadata': {'name': 'cloud'}, 'spec': {}}
        with self.assertRaisesRegex(RuntimeError, 'not owned'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_conflicting_existing_output_is_not_overwritten(self):
        self.output.write_text('kind: Link\nspec: {}\n')
        os.chmod(self.output, 0o600)
        with self.assertRaisesRegex(RuntimeError, 'different endpoint/client'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_output_symlink_rejected(self):
        self.output.symlink_to(Path(self.temp.name) / 'missing')
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_missing_controller_requires_explicit_install(self):
        self.cluster.deployment = None
        with self.assertRaisesRegex(RuntimeError, '--install-controller'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_explicit_install_only_installs_missing_controller(self):
        self.cluster.deployment = None
        del self.cluster.items['configmap', 'skupper']
        self.execute('--install-controller')
        installs = [c for c in self.cluster.commands if c[0] == 'helm' and 'install' in c]
        self.assertEqual(len(installs), 1)
        self.assertIn('scope=namespace', installs[0])
        self.assertIn('--atomic', installs[0])
        self.cluster.commands.clear()
        self.execute('--install-controller')
        self.assertFalse(any(c[0] == 'helm' for c in self.cluster.commands))

    def test_old_covering_controller_is_never_upgraded(self):
        self.cluster.deployment['spec']['template']['spec']['containers'][0]['image'] = 'quay.io/skupper/controller:2.1.4'
        with self.assertRaisesRegex(RuntimeError, 'no upgrades'):
            self.execute('--install-controller')
        self.assertFalse(self.cluster.writes)

    def test_incompatible_crd_rejected(self):
        self.cluster.items['crd', 'links.skupper.io']['spec']['versions'][0]['schema'] = {}
        with self.assertRaisesRegex(RuntimeError, 'CRD links.skupper.io'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_credential_name_collision_is_not_reused(self):
        self.cluster.items['certificates.skupper.io', 'client-customer-01'] = {'metadata': {}, 'spec': {}}
        with self.assertRaisesRegex(RuntimeError, 'credential name already exists'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_namespace_assignment_respected_for_cluster_controller(self):
        self.cluster.deployment['spec']['template']['spec']['containers'][0]['env'] = []
        self.cluster.items['configmap', 'skupper'] = {'data': {'controller': 'somewhere/other'}}
        with self.assertRaisesRegex(RuntimeError, 'No controller covers'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_ingress_class_retained_and_conflicting_change_fails(self):
        self.execute('--ingress-class', 'traefik-internal')
        route = self.cluster.items['ingressroutetcps.traefik.io', 'skupper']
        self.assertEqual(route['metadata']['annotations']['kubernetes.io/ingress.class'], 'traefik-internal')
        self.cluster.writes.clear()
        with self.assertRaisesRegex(RuntimeError, 'ingress class differs'):
            self.execute('--ingress-class', 'other')
        self.assertFalse(self.cluster.writes)

    def test_server_secret_collision_is_not_overwritten(self):
        self.cluster.items['secret', 'skupper-traefik-server'] = {'metadata': {'name': 'skupper-traefik-server'}}
        with self.assertRaisesRegex(RuntimeError, 'Server Secret already exists'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_unestablished_crd_rejected(self):
        self.cluster.items['crd', 'sites.skupper.io']['status'] = {}
        with self.assertRaisesRegex(RuntimeError, 'CRD sites.skupper.io'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_unrelated_environment_references_do_not_hide_controller(self):
        self.cluster.deployment['spec']['template']['spec']['containers'][0]['env'].append(
            {'name': 'POD_IP', 'valueFrom': {'fieldRef': {'fieldPath': 'status.podIP'}}})
        self.execute()
        self.assertTrue(self.output.exists())

    def test_interrupted_export_can_be_retried_without_rotation(self):
        original = self.cluster.run
        def interrupted(command, **kwargs):
            if command[0] == 'skupper' and 'generate' in command:
                raise RuntimeError('simulated export failure')
            return original(command, **kwargs)
        self.cluster.run = interrupted
        with self.assertRaisesRegex(RuntimeError, 'simulated export failure'):
            self.execute()
        self.assertFalse(self.output.exists())
        self.assertIn(('certificates.skupper.io', 'client-customer-01'), self.cluster.items)
        self.cluster.run = original
        self.execute()
        self.assertTrue(self.output.exists())

    def test_routing_key_contract_and_derived_name_limits(self):
        for flag, value in [('--routing-key', 'Customer/key'), ('--routing-key', 'x' * 64),
                            ('--site-name', 'x' * 59), ('--client-id', 'x' * 57)]:
            with self.subTest(flag=flag), self.assertRaises(RuntimeError):
                self.execute(flag, value)
        self.assertFalse(self.cluster.writes)

    def test_auth_denial_exit_status_preserves_clear_permission_error(self):
        self.mod.A = types.SimpleNamespace(timeout=1, context='test', namespace='cloud')
        denied = types.SimpleNamespace(returncode=1, stdout='no\n', stderr='')
        with patch.object(self.mod.subprocess, 'run', return_value=denied):
            self.assertEqual(self.mod.kube('auth', 'can-i', 'patch', 'sites.skupper.io').strip(), 'no')
            with self.assertRaisesRegex(RuntimeError, 'kubectl failed'):
                self.mod.kube('get', 'sites.skupper.io')

    def test_write_permission_checked_before_apply(self):
        original = self.cluster.run
        def denied(command, **kwargs):
            if 'auth' in command and 'patch' in command:
                return 'no\n'
            return original(command, **kwargs)
        self.cluster.run = denied
        with self.assertRaisesRegex(RuntimeError, 'Missing permission to patch'):
            self.execute()
        self.assertFalse(self.cluster.writes)

    def test_timeout_reports_resource_and_last_status(self):
        self.mod.A = types.SimpleNamespace(timeout=1)
        item = {'metadata': {'generation': 2}, 'status': {'message': 'waiting for router', 'conditions': [
            {'type': 'Ready', 'status': 'True', 'observedGeneration': 1}]}}
        with patch.object(self.mod, 'get', return_value=item), patch.object(self.mod.time, 'monotonic', side_effect=[0, 2]):
            with self.assertRaisesRegex(RuntimeError, 'Timed out.*waiting for router'):
                self.mod.wait('sites.skupper.io', 'cloud')


if __name__ == '__main__':
    unittest.main()
