#!/usr/bin/env python3
"""No-daemon regression tests for local-only ACL proof tooling."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class LocalDockerGuard(unittest.TestCase):
    def check_remote_refused(self, endpoint=None):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            marker = temp / "daemon-command"
            fake = temp / "docker"
            fake.write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
                            "if sys.argv[1:3]==['context','inspect']:\n print('ssh://remote.example');sys.exit(0)\n"
                            "Path(os.environ['GUARD_MARKER']).write_text('unexpected daemon operation')\n"
                            "sys.exit(2)\n")
            fake.chmod(0o700)
            environment = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ["PATH"],
                               GUARD_MARKER=str(marker), DOCKER_CONTEXT="selected-remote")
            if endpoint is None:
                environment.pop("DOCKER_HOST", None)
            else:
                environment["DOCKER_HOST"] = endpoint
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("check_redis_acl.py"))],
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), "Remote endpoint reached a Docker daemon command")
            self.assertIn("Unix Docker socket", result.stderr)

    def test_remote_host_refused_before_docker(self):
        self.check_remote_refused("tcp://remote.example:2375")

    def test_selected_remote_context_refused_before_daemon(self):
        self.check_remote_refused()


if __name__ == "__main__":
    unittest.main()
