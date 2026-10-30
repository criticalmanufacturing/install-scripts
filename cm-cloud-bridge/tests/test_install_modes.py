#!/usr/bin/env python3
"""Offline mode-selector checks using piped Bash and a real controlling terminal."""

import errno
import fcntl
import hashlib
import json
import os
import pathlib
import select
import signal
import subprocess
import tempfile
import termios
import time
import unittest


INSTALLER = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
SCRIPTS = {
    "native": "setup-cm-cloud-bridge-ubuntu-native.sh",
    "podman": "setup-cm-cloud-bridge-ubuntu.sh",
}

CURL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, urllib.parse

args = sys.argv[1:]
url = next((arg for arg in args if arg.startswith(('https://', 'http://'))), '')
parsed = urllib.parse.urlsplit(url)
fixture = pathlib.Path(os.environ['MODE_FIXTURES'])
with open(os.environ['MODE_REQUESTS'], 'a', encoding='utf-8') as stream:
    stream.write(json.dumps(args) + '\n')
expected = os.environ.get('MODE_REGISTRY', 'criticalmanufacturing.io')
version = os.environ.get('MODE_VERSION', '1.0.0')
prefix = '/repository/tools/cm-cloud-bridge-' + version + '/latest/'
if parsed.netloc != expected or not parsed.path.startswith(prefix) or parsed.query:
    print('Unexpected artifact URL', file=sys.stderr)
    sys.exit(98)
filename = parsed.path[len(prefix):]
if filename == os.environ.get('MODE_DOWNLOAD_FAILURE'):
    print('Synthetic download failure', file=sys.stderr)
    sys.exit(22)
data = (fixture / filename).read_bytes()
output = None
for index, value in enumerate(args):
    if value in ('-o', '--output'):
        output = args[index + 1]
    elif value.startswith('--output='):
        output = value.split('=', 1)[1]
if output is None:
    sys.stdout.buffer.write(data)
else:
    pathlib.Path(output).write_bytes(data)
'''

BLOCKED_TOOL = r'''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ['MODE_TOOLS'], 'a', encoding='utf-8') as stream:
    stream.write(pathlib.Path(sys.argv[0]).name + '\n')
print('Synthetic blocked Helm/cluster command', file=sys.stderr)
sys.exit(97)
'''


def backend(mode):
    return ("#!/usr/bin/env bash\nset -Eeuo pipefail\n"
            "python3 - \"$@\" <<'PYBACKEND'\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['MODE_EXECUTED']).write_text(json.dumps("
            + repr({"mode": mode}) + " | {'arguments': sys.argv[1:]}))\n"
            "print('Synthetic backend executed.')\n"
            "raise SystemExit(int(os.environ.get('MODE_BACKEND_EXIT', '0')))\n"
            "PYBACKEND\n").encode()


class InstallModes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="connector selector ")
        self.root = pathlib.Path(self.temp.name)
        self.work = self.root / "working folder"
        self.work.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tmp = self.root / "temporary files"
        self.tmp.mkdir()
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        self.requests = self.root / "requests.jsonl"
        self.tools = self.root / "tools.log"
        self.executed = self.root / "executed.json"
        for name, contents in (("curl", CURL), ("helm", BLOCKED_TOOL), ("kubectl", BLOCKED_TOOL)):
            path = self.bin / name
            path.write_text(contents)
            path.chmod(0o755)
        for mode, name in SCRIPTS.items():
            (self.fixtures / name).write_bytes(backend(mode))
        (self.fixtures / "VERSION").write_text("1.0.0\n")
        self.write_manifest()
        (self.work / "link.yaml").write_text("# SYNTHETIC_PRIVATE_LINK_MUST_NOT_APPEAR\n")
        (self.work / "app-values.yaml").write_text(
            "connectorName: fixture-app\nappIp: \"application.example.test\"\nappPort: 7990\n"
        )
        self.env = dict(os.environ,
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TMPDIR=str(self.tmp), MODE_FIXTURES=str(self.fixtures),
                        MODE_REQUESTS=str(self.requests), MODE_TOOLS=str(self.tools),
                        MODE_EXECUTED=str(self.executed))

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self):
        (self.fixtures / "SHA256SUMS").write_text("".join(
            hashlib.sha256((self.fixtures / name).read_bytes()).hexdigest() + "  ./" + name + "\n"
            for name in sorted(SCRIPTS.values())
        ))

    def run_installer(self, *arguments, selection=None, terminal=False, script=None):
        script = INSTALLER.read_bytes() if script is None else script
        command = ["/bin/bash", "-s", "--", *arguments]
        if not terminal:
            result = subprocess.run(command, input=script, cwd=self.work, env=self.env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    start_new_session=True, timeout=20)
            output = result.stdout.decode(errors="replace")
            status = result.returncode
        else:
            master, slave = os.openpty()

            def attach_terminal():
                os.setsid()
                fcntl.ioctl(1, termios.TIOCSCTTY, 0)

            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=slave,
                                       stderr=slave, cwd=self.work, env=self.env,
                                       preexec_fn=attach_terminal)
            os.close(slave)
            process.stdin.write(script)
            process.stdin.close()
            output_bytes = bytearray()
            answered = False
            deadline = time.monotonic() + 20
            try:
                while True:
                    if time.monotonic() >= deadline:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        self.fail("Mode terminal interaction exceeded deadline: " + output_bytes.decode(errors="replace"))
                    ready, _, _ = select.select([master], [], [], 0.1)
                    if ready:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not chunk:
                            break
                        output_bytes.extend(chunk)
                        lower = output_bytes.lower()
                        if selection is not None and not answered and all(
                                name in lower for name in (b"native", b"podman", b"helm")):
                            os.write(master, str(selection).encode() + b"\n")
                            answered = True
                    elif process.poll() is not None:
                        break
            finally:
                os.close(master)
            status = process.wait()
            output = output_bytes.decode(errors="replace").replace("\r\n", "\n")
        self.assertNotIn("SYNTHETIC_PRIVATE_LINK_MUST_NOT_APPEAR", output)
        self.assertEqual(list(self.tmp.iterdir()), [], "Temporary download files were retained")
        return status, output

    def downloaded(self):
        return [json.loads(line) for line in self.requests.read_text().splitlines()] if self.requests.exists() else []

    def assert_no_backend(self):
        self.assertFalse(self.executed.exists(), "An unverified or unselected backend executed")

    def assert_no_helm(self):
        self.assertFalse(self.tools.exists(), "Ubuntu mode invoked Helm or kubectl")

    def assert_backend(self, mode):
        self.assertTrue(self.executed.exists(), "Selected backend did not execute")
        result = json.loads(self.executed.read_text())
        self.assertEqual(result["mode"], mode)
        self.assert_no_helm()
        return result["arguments"]

    def test_help_without_terminal_or_dependencies(self):
        status, output = self.run_installer("--help")
        self.assertEqual(status, 0, output)
        self.assertIn("--mode", output)
        for name in ("native", "podman", "helm"):
            self.assertIn(name, output.lower())
        self.assertNotIn("--registry", output)
        self.assertEqual(self.downloaded(), [])
        self.assert_no_backend()
        self.assert_no_helm()

    def test_native_and_podman_flags_skip_menu(self):
        for mode in SCRIPTS:
            with self.subTest(mode=mode):
                self.executed.unlink(missing_ok=True)
                status, output = self.run_installer("--mode", mode)
                self.assertEqual(status, 0, output)
                args = self.assert_backend(mode)
                self.assertEqual(args[args.index("--connector-name") + 1], "fixture-app")
                self.assertEqual(args[args.index("--app-ip") + 1], "application.example.test")
                self.assertEqual(args[args.index("--app-port") + 1], "7990")
                self.assertTrue(any(SCRIPTS[mode] in arg for command in self.downloaded() for arg in command))

    def test_menu_native_and_podman_choices(self):
        for choice, mode in (("1", "native"), ("2", "podman"), ("native", "native"), ("podman", "podman")):
            with self.subTest(choice=choice):
                self.executed.unlink(missing_ok=True)
                status, output = self.run_installer(selection=choice, terminal=True)
                self.assertEqual(status, 0, output)
                self.assert_backend(mode)

    def test_helm_menu_choice_reaches_existing_helm_path(self):
        status, output = self.run_installer(selection="3", terminal=True)
        self.assertNotEqual(status, 0, "Synthetic Helm command should stop the test")
        self.assertTrue(self.tools.exists(), output)
        self.assertIn("helm", self.tools.read_text())
        self.assertEqual(self.downloaded(), [])
        self.assert_no_backend()

    def test_cancel_invalid_selection_and_missing_terminal(self):
        for selection, terminal in (("q", True), ("invalid", True), (None, False)):
            with self.subTest(selection=selection):
                status, output = self.run_installer(selection=selection, terminal=terminal)
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.downloaded(), [])
                self.assert_no_backend()
                self.assert_no_helm()

    def test_invalid_mode_and_ubuntu_version_fail_before_download(self):
        for args in (("--mode", "unknown"), ("--mode",),
                     ("--mode", "native", "--version", "1.0.0-beta"),
                     ("--mode", "native", "--version", "../wrong")):
            with self.subTest(arguments=args):
                status, output = self.run_installer(*args)
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.downloaded(), [])
                self.assert_no_backend()

    def test_explicit_version_registry_and_array_arguments(self):
        self.env.update(MODE_VERSION="2.3.4", MODE_REGISTRY="registry.example.test:5443")
        (self.fixtures / "VERSION").write_text("2.3.4\n")
        link = self.work / "private folder" / "another link.yaml"
        link.parent.mkdir()
        link.write_text("# SYNTHETIC_PRIVATE_LINK_MUST_NOT_APPEAR\n")
        status, output = self.run_installer(
            "--mode", "native", "--version", "2.3.4", "--registry", self.env["MODE_REGISTRY"],
            "--link-file", str(link), "--connector-name", "explicit-app", "--site-name", "vm-one",
            "--namespace", "vm-ns", "--routing-key", "app-route", "--app-ip", "other.example.test",
            "--app-port", "8080", "--cloud-host", "cloud.example.test", "--cloud-ip", "2001:db8::1",
            "--timeout", "120",
        )
        self.assertEqual(status, 0, output)
        arguments = self.assert_backend("native")
        final = dict(zip(arguments[::2], arguments[1::2]))
        self.assertEqual(final["--link-file"], str(link))
        for key, expected in (("--connector-name", "explicit-app"), ("--app-ip", "other.example.test"),
                              ("--app-port", "8080"), ("--namespace", "vm-ns"), ("--site-name", "vm-one"),
                              ("--routing-key", "app-route"), ("--cloud-ip", "2001:db8::1"), ("--timeout", "120")):
            self.assertEqual(final[key], expected)

    def test_failed_download_does_not_execute(self):
        for name in ("VERSION", "SHA256SUMS", SCRIPTS["native"]):
            with self.subTest(filename=name):
                self.env["MODE_DOWNLOAD_FAILURE"] = name
                status, output = self.run_installer("--mode", "native")
                self.assertNotEqual(status, 0, output)
                self.assert_no_backend()
                self.assert_no_helm()

    def test_explicit_settings_path_and_simple_quoted_values(self):
        values = self.work / "settings folder" / "supplied values.yaml"
        values.parent.mkdir()
        values.write_text(
            "# supplied example\r\nconnectorName: 'quoted-app'\r\n"
            "appIp: \"quoted.example.test\"\r\nappPort: 9000\r\n"
        )
        status, output = self.run_installer("--mode", "podman", "--values", str(values))
        self.assertEqual(status, 0, output)
        args = self.assert_backend("podman")
        final = dict(zip(args[::2], args[1::2]))
        self.assertEqual(final["--connector-name"], "quoted-app")
        self.assertEqual(final["--app-ip"], "quoted.example.test")
        self.assertEqual(final["--app-port"], "9000")

    def test_missing_optional_defaults_leave_inputs_to_backend(self):
        (self.work / "app-values.yaml").unlink()
        (self.work / "link.yaml").unlink()
        status, output = self.run_installer("--mode", "native")
        self.assertEqual(status, 0, output)
        self.assertEqual(self.assert_backend("native"), [])

    def test_bad_supplied_settings_stop_before_download(self):
        cases = (
            "connectorName: fixture\nappPort: 7990\n",
            "connectorName: fixture\nconnectorName: repeated\nappIp: host\nappPort: 7990\n",
            'connectorName: fixture\nappIp: "escaped\\\\host"\nappPort: 7990\n',
            "connectorName: fixture\nappIp: [host]\nappPort: 7990\n",
        )
        for values in cases:
            with self.subTest(settings=values):
                (self.work / "app-values.yaml").write_text(values)
                status, output = self.run_installer("--mode", "native")
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.downloaded(), [])
                self.assert_no_backend()

    def test_explicit_missing_files_stop_before_download(self):
        for option in ("--values", "--link-file"):
            with self.subTest(option=option):
                status, output = self.run_installer("--mode", "native", option, "missing file.yaml")
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.downloaded(), [])
                self.assert_no_backend()

    def test_cross_mode_options_stop_before_download_or_helm(self):
        for args in (("--mode", "native", "--release", "helm-only"),
                     ("--mode", "helm", "--app-ip", "vm-only.example.test")):
            with self.subTest(arguments=args):
                status, output = self.run_installer(*args)
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.downloaded(), [])
                self.assert_no_backend()
                self.assert_no_helm()

    def test_mismatched_version_does_not_execute(self):
        (self.fixtures / "VERSION").write_text("9.9.9\n")
        status, output = self.run_installer("--mode", "native")
        self.assertNotEqual(status, 0, output)
        self.assert_no_backend()

    def test_corrupt_or_truncated_download_does_not_execute(self):
        for content in (b"#!/usr/bin/env bash\necho corrupted\n", b"#!/usr/bin/env bash\nmain() {\n"):
            with self.subTest(content=content):
                (self.fixtures / SCRIPTS["native"]).write_bytes(content)
                status, output = self.run_installer("--mode", "native")
                self.assertNotEqual(status, 0, output)
                self.assert_no_backend()

    def test_bad_or_ambiguous_manifest_does_not_execute(self):
        valid = (self.fixtures / "SHA256SUMS").read_text()
        native_line = next(line for line in valid.splitlines() if SCRIPTS["native"] in line)
        cases = ("", valid.replace(native_line, "not-a-hash  ./" + SCRIPTS["native"]),
                 valid + native_line + "\n", "\n".join(line for line in valid.splitlines() if SCRIPTS["native"] not in line))
        for contents in cases:
            with self.subTest(manifest=contents):
                (self.fixtures / "SHA256SUMS").write_text(contents)
                status, output = self.run_installer("--mode", "native")
                self.assertNotEqual(status, 0, output)
                self.assert_no_backend()

    def test_syntax_invalid_but_hash_matching_backend_does_not_execute(self):
        (self.fixtures / SCRIPTS["native"]).write_text("#!/usr/bin/env bash\nmain() {\n")
        self.write_manifest()
        status, output = self.run_installer("--mode", "native")
        self.assertNotEqual(status, 0, output)
        self.assert_no_backend()

    def test_backend_failure_propagates(self):
        self.env["MODE_BACKEND_EXIT"] = "23"
        status, output = self.run_installer("--mode", "podman")
        self.assertEqual(status, 23, output)
        self.assert_backend("podman")

    def test_truncated_selector_cannot_start_installation(self):
        script = INSTALLER.read_bytes()
        marker = script.rfind(b"\n}")
        self.assertGreater(marker, 0)
        status, output = self.run_installer("--mode", "native", script=script[:marker])
        self.assertNotEqual(status, 0, output)
        self.assertEqual(self.downloaded(), [])
        self.assert_no_backend()


if __name__ == "__main__":
    unittest.main()
