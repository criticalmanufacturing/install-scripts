#!/usr/bin/env python3
"""Check private, complete logs from the actual piped installer without installing."""

import base64
import shutil
import stat
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
import test_install_modes as fixtures


class InstallLogs(unittest.TestCase):
    setUp = fixtures.InstallModes.setUp
    tearDown = fixtures.InstallModes.tearDown
    run_installer = fixtures.InstallModes.run_installer
    write_manifest = fixtures.InstallModes.write_manifest
    downloaded = fixtures.InstallModes.downloaded
    assert_no_backend = fixtures.InstallModes.assert_no_backend

    def logs(self, directory=None):
        return sorted((directory or self.work).glob("cm-cloud-bridge-install-*.log"))

    def assert_log(self, status, output, directory=None):
        logs = self.logs(directory)
        self.assertEqual(len(logs), 1, output)
        log = logs[0]
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
        content = log.read_text()
        self.assertTrue(content.endswith(f"Installer exit status: {status}\n"), content)
        self.assertTrue(output.rstrip().endswith(f"Installation log: {log}"), output)
        for private in ("SYNTHETIC_PRIVATE_LINK_MUST_NOT_APPEAR", "PRIVATE_RENDERED_LINK_FIXTURE",
                        "synthetic-private-registry-token",
                        base64.b64encode(b"fixture-user:synthetic-private-registry-token").decode()):
            self.assertNotIn(private, content)
        return content

    def run_direct(self, *arguments):
        result = subprocess.run(
            ["/bin/bash", "-s", "--", *arguments], input=fixtures.INSTALLER.read_bytes(),
            cwd=self.work, env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, start_new_session=True, timeout=20,
        )
        return result.returncode, result.stdout.decode(errors="replace")

    def verbose_backend(self):
        path = self.fixtures / fixtures.SCRIPTS["native"]
        content = path.read_text().replace(
            "print('Synthetic backend executed.')",
            "print('Synthetic backend executed.')\n"
            "print('Synthetic build diagnostic on stderr.', file=sys.stderr)\n"
            "for number in range(300): print('Synthetic build line', number)\n"
            "print('Synthetic final build line.')",
        )
        path.write_text(content)
        self.write_manifest()

    def test_success_captures_stdout_stderr_and_final_lines(self):
        self.verbose_backend()
        self.env["REGISTRY_TOKEN"] = "synthetic-private-registry-token"
        status, output = self.run_installer("--mode", "native")
        self.assertEqual(status, 0, output)
        content = self.assert_log(0, output)
        for message in ("Selected version: 1.0.0", "Synthetic backend executed.",
                        "Synthetic build diagnostic on stderr.", "Synthetic build line 299",
                        "Synthetic final build line."):
            self.assertIn(message, content)
            self.assertIn(message, output)

    def test_backend_failure_keeps_exact_status_and_log(self):
        self.env["MODE_BACKEND_EXIT"] = "23"
        status, output = self.run_installer("--mode", "podman")
        self.assertEqual(status, 23, output)
        content = self.assert_log(23, output)
        self.assertIn("Synthetic backend executed.", content)
        self.assertIn("Installation stopped while running the Ubuntu installer", content)

    def test_terminal_menu_still_works_with_piped_content(self):
        status, output = self.run_installer(selection="1", terminal=True)
        self.assertEqual(status, 0, output)
        content = self.assert_log(0, output)
        self.assertIn("Choose how to install the CM Cloud Bridge", content)
        self.assertIn("Synthetic backend executed.", content)

    def test_cancel_and_invalid_arguments_still_leave_a_log(self):
        for arguments, selection, terminal in (((), "q", True), (("--mode", "unknown"), None, False)):
            with self.subTest(arguments=arguments):
                for log in self.logs():
                    log.unlink()
                status, output = self.run_installer(*arguments, selection=selection, terminal=terminal)
                self.assertNotEqual(status, 0, output)
                self.assert_log(status, output)
                self.assert_no_backend()
                self.assertEqual(self.downloaded(), [])

    def test_help_creates_no_log_or_download(self):
        for arguments in (("--help",), ("-h",)):
            with self.subTest(arguments=arguments):
                status, output = self.run_installer(*arguments)
                self.assertEqual(status, 0, output)
                self.assertNotIn("Installation log:", output)
                self.assertEqual(self.logs(), [])
                self.assertEqual(self.logs(self.tmp), [])
                self.assertEqual(self.downloaded(), [])

    def test_missing_logging_tools_preserves_installation_errors(self):
        no_tools = self.root / "no tools"
        no_tools.mkdir()
        self.env["PATH"] = str(no_tools)
        status, output = self.run_direct("--mode", "helm")
        self.assertNotEqual(status, 0, output)
        self.assertIn("Install helm before running this installer.", output)
        self.assertIn("Installation logging is unavailable", output)
        self.assertEqual(self.logs(), [])
        self.assertEqual(list(self.tmp.iterdir()), [])
        (no_tools / "cat").symlink_to(shutil.which("cat"))
        status, output = self.run_direct("--help")
        self.assertEqual(status, 0, output)
        self.assertNotIn("logging is unavailable", output)
        self.assertEqual(self.logs(), [])

    def test_cwd_log_failure_falls_back_to_private_temporary_log(self):
        mktemp = shutil.which("mktemp")
        self.assertIsNotNone(mktemp)
        self.env["MODE_LOG_CWD"] = str(self.work)
        stub = self.bin / "mktemp"
        stub.write_text(
            '#!/bin/bash\n'
            'if [[ $1 == "$MODE_LOG_CWD"/cm-cloud-bridge-install-* ]]; then exit 1; fi\n'
            'exec "' + mktemp + '" "$@"\n'
        )
        stub.chmod(0o755)
        status, output = self.run_direct("--mode", "native")
        self.assertEqual(status, 0, output)
        self.assertEqual(self.logs(), [])
        self.assert_log(0, output, self.tmp)
        self.assertEqual(list(self.tmp.iterdir()), self.logs(self.tmp))

    def test_unavailable_log_locations_preserve_main_error(self):
        stub = self.bin / "mktemp"
        stub.write_text("#!/bin/bash\nexit 1\n")
        stub.chmod(0o755)
        status, output = self.run_direct("--mode", "unknown")
        self.assertNotEqual(status, 0, output)
        self.assertIn("Cannot create an installation log", output)
        self.assertIn("Installation mode must be native, podman, or helm.", output)
        self.assertEqual(self.logs(), [])
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_failed_tee_is_reported_without_masking_backend_failure(self):
        stub = self.bin / "tee"
        stub.write_text("#!/bin/bash\ncat >/dev/null\nexit 7\n")
        stub.chmod(0o755)
        for backend_status, expected in (("0", 7), ("23", 23)):
            with self.subTest(backend_status=backend_status):
                for log in self.logs():
                    log.unlink()
                self.env["MODE_BACKEND_EXIT"] = backend_status
                status, output = self.run_installer("--mode", "native")
                self.assertEqual(status, expected, output)
                self.assertIn("The installation log could not capture all output.", output)
                self.assert_log(expected, output)


if __name__ == "__main__":
    unittest.main()
