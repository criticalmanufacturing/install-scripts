#!/usr/bin/env bash
# Configure the cloud side of a Skupper 2.2.3 TCP connection through existing Traefik.
# Python safely handles Kubernetes JSON, YAML credentials, and atomic secret files.
# No application/cluster credentials are written to the repository or printed.
set -Eeuo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'ERROR: Install Python 3 and PyYAML on this administrator workstation.' >&2; exit 1; }
exec python3 - "$@" <<'PYTHON'
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit('ERROR: Install PyYAML on this administrator workstation (Ubuntu: sudo apt install python3-yaml).')

VERSION = '2.2.3'
OWNER = 'install-scripts.criticalmanufacturing.com/skupper-cloud-listener'


def fail(message):
    raise RuntimeError(message)


def arguments():
    parser = argparse.ArgumentParser(prog='setup-skupper-cloud-listener.sh', description='Configure a Skupper cloud listener using existing Traefik TCP passthrough.')
    for name in ('context', 'namespace', 'listener-name', 'listener-port', 'routing-key', 'cloud-host', 'client-id', 'link-output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--site-name')
    parser.add_argument('--cloud-port', default='443')
    parser.add_argument('--entrypoint', default='websecure')
    parser.add_argument('--ingress-class')
    parser.add_argument('--timeout', type=int, default=180, help='Readiness timeout in seconds (default: 180).')
    parser.add_argument('--install-controller', action='store_true', help='Install a namespace-scoped controller if no controller covers this namespace; never upgrade.')
    args = parser.parse_args()
    args.site_name = args.site_name or args.namespace
    for key, limit in (('namespace', 63), ('site_name', 58), ('listener_name', 63), ('client_id', 56), ('routing_key', 63)):
        value = getattr(args, key)
        if len(value) > limit or not re.fullmatch(r'[a-z0-9](?:[-a-z0-9]*[a-z0-9])?', value):
            fail(f'--{key.replace("_", "-")} must be a lowercase DNS label of at most {limit} characters.')
    if not args.context.strip() or args.context.startswith('-'):
        fail('--context must name a kubeconfig context.')
    for key in ('listener_port', 'cloud_port'):
        value = getattr(args, key)
        if not value.isascii() or not value.isdigit() or not 1 <= int(value) <= 65535:
            fail(f'--{key.replace("_", "-")} must be an integer from 1 to 65535.')
    if len(args.cloud_host) > 253 or '.' not in args.cloud_host or any(not re.fullmatch(r'[a-zA-Z0-9](?:[-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?', label) for label in args.cloud_host.split('.')):
        fail('--cloud-host must be a DNS hostname, used for TLS identity and Traefik SNI.')
    if re.fullmatch(r'[0-9.]+', args.cloud_host):
        fail('--cloud-host must be a hostname, not an IP address.')
    for key in ('entrypoint', 'ingress_class'):
        if getattr(args, key) and not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}', getattr(args, key)):
            fail(f'Invalid --{key.replace("_", "-")}.')
    if not 1 <= args.timeout <= 3600:
        fail('--timeout must be between 1 and 3600 seconds.')
    return args


def run(command, *, data=None, secret=False, timeout=None):
    try:
        result = subprocess.run(command, input=data, text=True, capture_output=True, timeout=timeout or A.timeout + 30)
    except subprocess.TimeoutExpired:
        fail(f'{Path(command[0]).name} timed out; check cluster access and retry.')
    if result.returncode:
        detail = 'Credential command failed; inspect the Certificate status without printing its Secret.' if secret else result.stderr.strip()[-3000:]
        fail(f'{Path(command[0]).name} failed: {detail or "command returned an error"}')
    return result.stdout


def kube(*command, data=None, namespace=True):
    prefix = ['kubectl', '--context', A.context, '--request-timeout=30s']
    if namespace:
        prefix += ['--namespace', A.namespace]
    return run(prefix + list(command), data=data)


def get(kind, name=None, *, namespace=True):
    command = ['get', kind]
    if name:
        command += [name, '--ignore-not-found']
    result = kube(*command, '-o', 'json', namespace=namespace)
    return json.loads(result) if result.strip() else None


def resource(kind, name, spec, api='skupper.io/v2alpha1'):
    return {'apiVersion': api, 'kind': kind,
            'metadata': {'name': name, 'namespace': A.namespace, 'annotations': {OWNER: A.site_name}}, 'spec': spec}


def check_owned(kind, desired):
    existing = get(kind, desired['metadata']['name'])
    if existing and existing.get('metadata', {}).get('annotations', {}).get(OWNER) != A.site_name:
        fail(f'{kind}/{desired["metadata"]["name"]} already exists and is not owned by this installer. Choose a dedicated namespace/resource name.')
    # Changing a public hostname or a route identity invalidates already exported links.
    if existing and kind in ('certificates.skupper.io', 'routeraccesses.skupper.io', 'ingressroutetcps.traefik.io'):
        if existing.get('spec') != desired['spec']:
            fail(f'{kind}/{desired["metadata"]["name"]} configuration differs. Existing link credentials will not be silently rotated; review migration explicitly.')
    return existing


def apply(document):
    # Server-side apply avoids a last-applied annotation containing credentials.
    kube('apply', '--server-side', '--field-manager=skupper-cloud-listener', '-f', '-', data=json.dumps(document))


def wait(kind, name, condition='Ready'):
    deadline = time.monotonic() + A.timeout
    last = 'not present'
    while True:
        item = get(kind, name)
        if item:
            last = item.get('status', {}).get('message', 'not ready')
            generation = item.get('metadata', {}).get('generation', 1)
            for entry in item.get('status', {}).get('conditions', []):
                if entry.get('type') == condition and entry.get('status') == 'True' and entry.get('observedGeneration', generation) >= generation:
                    return item
            if item.get('status', {}).get('status') == 'Error':
                fail(f'{kind}/{name}: {last}')
        if time.monotonic() >= deadline:
            fail(f'Timed out waiting for {kind}/{name} {condition}: {last}. Check controller/router status and events.')
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def controller_coverage():
    # A cluster-wide read is intentional: namespace-only discovery could install a second controller.
    deployments = json.loads(kube('get', 'deployments', '--all-namespaces', '-o', 'json', namespace=False))['items']
    assignment = (get('configmap', 'skupper') or {}).get('data', {}).get('controller')
    if assignment and '/' not in assignment:
        assignment = A.namespace + '/' + assignment
    candidates = []
    for deployment in deployments:
        metadata = deployment['metadata']
        for container in deployment.get('spec', {}).get('template', {}).get('spec', {}).get('containers', []):
            image = container.get('image', '')
            if not (re.search(r'(^|/)skupper/(?:skupper-)?controller(?:[:@]|$)', image) or re.search(r'(^|/)skupper-controller(?:[:@]|$)', image) or metadata.get('labels', {}).get('app.kubernetes.io/name') == 'skupper-controller'):
                continue
            env = {}
            for entry in container.get('env', []):
                if entry.get('name') not in ('WATCH_NAMESPACE', 'CONTROLLER_NAME', 'REQUIRE_EXPLICIT_CONTROL'):
                    continue
                if 'value' in entry:
                    env[entry['name']] = entry['value']
                elif entry.get('valueFrom', {}).get('fieldRef', {}).get('fieldPath') == 'metadata.namespace':
                    env[entry['name']] = metadata['namespace']
                else:
                    fail('Controller environment uses indirect values; an administrator must verify controller coverage explicitly.')
            if container.get('envFrom'):
                fail('Controller envFrom prevents reliable scope discovery; ask the cluster administrator to expose controller scope explicitly.')
            options = dict(env)
            tokens = container.get('command', []) + container.get('args', [])
            for index, token in enumerate(tokens):
                token = '--' + token.lstrip('-') if token.startswith('-') else token
                for flag, key in (('--watch-namespace', 'WATCH_NAMESPACE'), ('--name', 'CONTROLLER_NAME'), ('--require-explicit-control', 'REQUIRE_EXPLICIT_CONTROL')):
                    if token.startswith(flag + '='):
                        options[key] = token.split('=', 1)[1]
                    elif token == flag:
                        options[key] = tokens[index + 1] if index + 1 < len(tokens) and not tokens[index + 1].startswith('-') else 'true'
            watch = options.get('WATCH_NAMESPACE', '')
            if '$' in watch:
                fail('Controller watch namespace contains unresolved environment substitution.')
            identity = metadata['namespace'] + '/' + options.get('CONTROLLER_NAME', metadata['name'])
            explicit = bool(watch) or options.get('REQUIRE_EXPLICIT_CONTROL', 'false').lower() == 'true'
            covers = (not watch or watch == A.namespace) and ((assignment == identity) if assignment else not explicit)
            if covers:
                if not image.endswith(':' + VERSION):
                    fail(f'Controller {identity} covers this namespace but its image is not pinned to {VERSION}; no upgrades are performed.')
                candidates.append((metadata['namespace'], metadata['name']))
    if len(candidates) > 1:
        fail('Multiple controllers cover this namespace; resolve ownership before continuing.')
    return candidates


def check_crds():
    required = {'sites': ('linkAccess', 'ha'), 'listeners': ('routingKey', 'port', 'host'),
                'routeraccesses': ('accessType', 'roles', 'tlsCredentials'), 'certificates': ('ca', 'hosts', 'client', 'server'),
                'links': ('endpoints', 'tlsCredentials')}
    for name, fields in required.items():
        crd = get('crd', name + '.skupper.io', namespace=False)
        versions = (crd or {}).get('spec', {}).get('versions', [])
        schema = next((v.get('schema', {}).get('openAPIV3Schema', {}).get('properties', {}).get('spec', {}).get('properties', {}) for v in versions if v.get('name') == 'v2alpha1' and v.get('served')), {})
        established = any(c.get('type') == 'Established' and c.get('status') == 'True' for c in (crd or {}).get('status', {}).get('conditions', []))
        if not established or not all(field in schema for field in fields):
            fail(f'CRD {name}.skupper.io lacks the required v2alpha1 schema. Have the cluster administrator install compatible 2.2.3 CRDs; this script does not upgrade them.')


def output_path():
    path = Path(A.link_output).absolute()
    if not path.parent.is_dir():
        fail('--link-output parent directory must already exist.')
    if path.is_symlink():
        fail('--link-output must not be a symlink.')
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            fail('Existing link output must be a regular file owned by this user with mode 0600.')
        try:
            documents = list(yaml.safe_load_all(path.read_text()))
            links = [d for d in documents if isinstance(d, dict) and d.get('kind') == 'Link']
            if len(links) != 1 or links[0].get('spec', {}).get('tlsCredentials') != CLIENT or links[0]['spec'].get('endpoints') != [{'name': 'inter-router', 'host': A.cloud_host, 'port': A.cloud_port}]:
                fail('Existing output belongs to a different endpoint/client. Choose a new file; existing output will not be overwritten.')
        except (ValueError, KeyError, yaml.YAMLError):
            fail('Existing link output is not a valid credential bundle.')
    return path


def export_link(path):
    # Distinct Certificate names prevent the CLI's default credential reuse across customers.
    deadline = time.monotonic() + A.timeout
    while not (get('sites.skupper.io', A.site_name) or {}).get('status', {}).get('endpoints'):
        if time.monotonic() >= deadline:
            fail('Timed out waiting for Site link endpoints after RouterAccess configuration.')
        time.sleep(2)
    raw = run(['skupper', '--platform', 'kubernetes', '--context', A.context, '--namespace', A.namespace,
               'link', 'generate', '--tls-credentials', CLIENT, '--timeout', str(A.timeout) + 's'], secret=True)
    documents = [d for d in yaml.safe_load_all(raw) if d]
    links = [d for d in documents if d.get('kind') == 'Link']
    secrets = [d for d in documents if d.get('kind') == 'Secret']
    if len(links) != 1 or len(secrets) != 1 or len(documents) != 2:
        fail('Expected one Link and one Secret from the single-router site; no output was written.')
    link, secret = links[0], secrets[0]
    if secret.get('metadata', {}).get('name') != CLIENT or link.get('spec', {}).get('tlsCredentials') != CLIENT or not all(secret.get('data', {}).get(k) for k in ('tls.crt', 'tls.key', 'ca.crt')):
        fail('Generated bundle is incomplete or references unexpected credentials; no output was written.')
    link['metadata'] = {'name': 'link-' + A.site_name}
    link['spec']['endpoints'] = [{'name': 'inter-router', 'host': A.cloud_host, 'port': A.cloud_port}]
    secret['metadata'] = {'name': CLIENT}
    encoded = yaml.safe_dump_all([link, secret], sort_keys=False)
    if path.exists():
        if list(yaml.safe_load_all(path.read_text())) != [link, secret]:
            fail('Existing output differs from generated credentials; refusing overwrite. Review credential migration explicitly.')
        return
    # Publish with an exclusive hard link; another process cannot race us into overwriting a secret.
    handle, temporary = tempfile.mkstemp(prefix='.skupper-link-', dir=path.parent)
    try:
        with os.fdopen(handle, 'w') as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def main():
    global A, CLIENT
    A = arguments()
    CLIENT = 'client-' + A.client_id
    path = output_path()
    for executable in ('kubectl', 'skupper'):
        if not shutil.which(executable):
            fail(f'Install {executable} on this administrator workstation.')
    actual = run(['skupper', 'version']).strip()
    if actual.lstrip('v') != VERSION:
        fail(f'Skupper CLI {VERSION} is required (reported {actual!r}).')
    if not get('namespace', A.namespace, namespace=False):
        fail('The requested namespace must already exist.')
    # Traefik itself, its public address, entrypoint, and firewall remain administrator prerequisites.
    ingress_crd = get('crd', 'ingressroutetcps.traefik.io', namespace=False)
    if not ingress_crd or not any(v.get('name') == 'v1alpha1' and v.get('served') for v in ingress_crd.get('spec', {}).get('versions', [])):
        fail('Existing Traefik IngressRouteTCP v1alpha1 CRDs are required. This installer does not install Traefik.')
    # Check write privileges before controller installation or the first application apply.
    for kind in ('sites.skupper.io', 'certificates.skupper.io', 'routeraccesses.skupper.io', 'listeners.skupper.io', 'ingressroutetcps.traefik.io'):
        for verb in ('create', 'patch'):
            if kube('auth', 'can-i', verb, kind).strip() != 'yes':
                fail(f'Missing permission to {verb} {kind} in namespace {A.namespace}.')
    controllers = controller_coverage()
    if not controllers:
        if not A.install_controller:
            fail('No controller covers this namespace. Install one explicitly with --install-controller, or ask the cluster administrator to assign an existing controller.')
        if not shutil.which('helm'):
            fail('Helm 3 is required with --install-controller.')
        if not run(['helm', 'version', '--template', '{{.Version}}']).strip().startswith('v3.'):
            fail('Helm 3 is required with --install-controller.')
        # Existing CRDs are checked before Helm; Helm must never silently repair or upgrade them.
        if get('crd', 'sites.skupper.io', namespace=False):
            check_crds()
        if get('deployment', 'skupper-controller') or get('configmap', 'skupper'):
            fail('Existing controller resources/assignment conflict with a new install; resolve them before installation.')
        print('Installing namespace-scoped Skupper controller 2.2.3...', flush=True)
        run(['helm', '--kube-context', A.context, 'install', 'skupper', 'oci://quay.io/skupper/helm/skupper',
             '--version', VERSION, '--namespace', A.namespace, '--set', 'scope=namespace', '--wait', '--atomic', '--timeout', str(A.timeout) + 's'])
        controllers = controller_coverage()
        if len(controllers) != 1:
            fail('Installed controller does not cover the requested namespace; inspect ConfigMap/skupper assignment.')
    check_crds()
    controller_namespace, controller_name = controllers[0]
    run(['kubectl', '--context', A.context, '--request-timeout=30s', '--namespace', controller_namespace,
         'rollout', 'status', 'deployment/' + controller_name, '--timeout=' + str(A.timeout) + 's'])
    sites = get('sites.skupper.io')['items']
    if any(item['metadata']['name'] != A.site_name for item in sites):
        fail('Another Site exists in this namespace. Use a dedicated namespace; only one active Site is supported.')
    site = resource('Site', A.site_name, {'linkAccess': 'none', 'ha': False})
    certificate = resource('Certificate', 'skupper-traefik-server', {'ca': 'skupper-site-ca', 'subject': A.cloud_host, 'hosts': [A.cloud_host], 'server': True})
    access = resource('RouterAccess', 'skupper-traefik', {'accessType': 'local', 'tlsCredentials': 'skupper-traefik-server', 'generateTlsCredentials': False, 'roles': [{'name': 'inter-router', 'port': 55671}]})
    route = resource('IngressRouteTCP', 'skupper', {'entryPoints': [A.entrypoint], 'routes': [{'match': 'HostSNI(`' + A.cloud_host + '`)', 'services': [{'name': 'skupper-traefik', 'port': 55671}]}], 'tls': {'passthrough': True}}, 'traefik.io/v1alpha1')
    if A.ingress_class:
        # The annotation supports older installed CRDs too; never remove an existing class.
        route['metadata']['annotations']['kubernetes.io/ingress.class'] = A.ingress_class
    listener = resource('Listener', A.listener_name, {'routingKey': A.routing_key, 'port': int(A.listener_port), 'host': A.listener_name, 'type': 'tcp'})
    desired = [('sites.skupper.io', site), ('certificates.skupper.io', certificate), ('routeraccesses.skupper.io', access), ('ingressroutetcps.traefik.io', route), ('listeners.skupper.io', listener)]
    for kind, document in desired:
        existing = check_owned(kind, document)
        if kind == 'sites.skupper.io' and existing and (existing.get('spec', {}).get('linkAccess', 'none') != 'none' or existing.get('spec', {}).get('ha') or existing.get('spec', {}).get('edge') or existing.get('spec', {}).get('defaultIssuer')):
            fail('Existing Site uses HA, edge mode or a custom issuer; this installer requires a single interior router with the default CA.')
        if kind == 'ingressroutetcps.traefik.io' and existing and existing.get('metadata', {}).get('annotations', {}).get('kubernetes.io/ingress.class') != A.ingress_class:
            fail('Existing Traefik ingress class differs; refusing to change route ownership.')
    # Preflight namespace-wide route collisions before creating any application resources.
    for other in json.loads(kube('get', 'ingressroutetcps.traefik.io', '--all-namespaces', '-o', 'json', namespace=False))['items']:
        if (other['metadata']['name'] != 'skupper' or other['metadata']['namespace'] != A.namespace) and A.entrypoint in other.get('spec', {}).get('entryPoints', []) and any('`' + A.cloud_host + '`' in entry.get('match', '') for entry in other.get('spec', {}).get('routes', [])):
            fail('Another Traefik TCP route already claims this hostname and entrypoint.')
    if get('secret', 'skupper-traefik-server') and not get('certificates.skupper.io', 'skupper-traefik-server'):
        fail('Server Secret already exists without its managed Certificate; resolve the name conflict before continuing.')
    client_certificate = get('certificates.skupper.io', CLIENT)
    if client_certificate and client_certificate.get('metadata', {}).get('annotations', {}).get(OWNER) != A.site_name:
        fail('Client credential name already exists and is not owned by this installer; choose a new --client-id.')
    if get('secret', CLIENT) and not client_certificate:
        fail('Client Secret already exists without its managed Certificate; choose a new --client-id.')
    client_document = resource('Certificate', CLIENT, {'ca': 'skupper-site-ca', 'subject': A.cloud_host, 'client': True})
    if client_certificate and client_certificate.get('spec') != client_document['spec']:
        fail('Existing client Certificate differs; refusing implicit credential rotation.')
    print('Configuring cloud Site, TLS passthrough, and application listener...', flush=True)
    apply(site)
    active_site = wait('sites.skupper.io', A.site_name)
    if active_site.get('status', {}).get('controller', {}).get('version', '').lstrip('v') != VERSION:
        fail('The active Site is not reconciled by a Skupper 2.2.3 controller.')
    apply(certificate)
    wait('certificates.skupper.io', 'skupper-traefik-server')
    apply(access)
    wait('routeraccesses.skupper.io', 'skupper-traefik')
    apply(route)
    apply(listener)
    wait('listeners.skupper.io', A.listener_name, 'Configured')
    # Pre-create our distinct client Certificate so interrupted runs retain clear ownership.
    apply(client_document)
    wait('certificates.skupper.io', CLIENT)
    export_link(path)
    print(f'Cloud configuration ready. Private link bundle: {path} (0600).')
    print(f'Cloud applications connect to {A.listener_name}:{A.listener_port}; routing key: {A.routing_key}.')
    print('Transfer the bundle securely to one connector site. End-to-end connectivity must be checked after that site connects.')


try:
    main()
except (RuntimeError, OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
    # YAML errors may contain secret lines: keep those diagnostics generic.
    message = 'Invalid YAML/JSON returned while handling credentials or cluster resources.' if isinstance(error, yaml.YAMLError) else str(error)
    print('ERROR: ' + message, file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    print('ERROR: Interrupted; configured resources are retained for a safe rerun.', file=sys.stderr)
    sys.exit(130)
PYTHON
