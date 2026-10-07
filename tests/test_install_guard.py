"""O install.sh não pode tocar no checkout nem no venv com o app aberto."""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"


def _fake_pgrep(directory: Path, exit_code: int) -> Path:
    script = directory / "fake-pgrep"
    script.write_text(f"#!/bin/sh\nexit {exit_code}\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script


class InstallGuardTest(unittest.TestCase):
    def _run(self, pgrep_exit: int):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = dict(os.environ)
            env["MEETING_TRANSCRIBER_PGREP"] = str(_fake_pgrep(tmp_path, pgrep_exit))
            # Se a guarda falhar, o script tenta clonar daqui e para sem efeito.
            env["MEETING_TRANSCRIBER_REPO_URL"] = str(tmp_path / "repo-inexistente.git")
            env["MEETING_TRANSCRIBER_PROJECT_DIR"] = str(tmp_path / "checkout")
            env.pop("ALLOW_RUNNING_INSTALL", None)
            result = subprocess.run(
                ["bash", str(INSTALL)], cwd=tmp, env=env,
                capture_output=True, text=True, timeout=60,
            )
            touched = sorted(p.name for p in tmp_path.iterdir() if p.name not in {"fake-pgrep"})
            return result, touched

    def test_running_app_stops_the_install_before_any_change(self):
        result, touched = self._run(pgrep_exit=0)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("aberto", result.stderr)
        self.assertEqual(touched, [], "nada pode ser criado antes da guarda")

    def test_closed_app_passes_the_guard(self):
        result, _ = self._run(pgrep_exit=1)
        # Passa da guarda e falha depois (clone de repo inexistente), nunca com 2.
        self.assertNotEqual(result.returncode, 2, result.stderr)
        self.assertNotIn("está aberto", result.stderr)


if __name__ == "__main__":
    unittest.main()
