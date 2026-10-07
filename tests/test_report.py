"""report.py: manifests sintéticos v1 e v2, sem dados reais."""
import csv
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import report  # noqa: E402

SECRET_TITLE = "Reunião Confidencial Exemplo"
SECRET_SPEECH = "frase secreta que nunca pode aparecer"


def v1_manifest(output_path=None, diagnostics=None, **extra):
    manifest = {
        "schemaVersion": 1,
        "id": "11111111-2222-3333-4444-555555555555",
        "title": SECRET_TITLE,
        "language": "pt",
        "outputDirectory": "/tmp/out",
        "micPath": "/tmp/mic.wav",
        "systemPath": "/tmp/system.wav",
        "sysOffsetMs": 0,
        "createdAt": "2026-10-02T12:00:00Z",
        "startedAt": "2026-10-02T12:30:00Z",
        "completedAt": "2026-10-02T12:45:00Z",
        "state": "succeeded",
        "progress": 100,
        "exportedToSecondBrain": False,
        "hidden": False,
        "captureIntegrity": {"status": "degraded", "details": ["mic atrasou"]},
    }
    if output_path:
        manifest["outputPath"] = output_path
    if diagnostics is not None:
        manifest["captureIntegrity"]["diagnostics"] = diagnostics
    manifest.update(extra)
    return manifest


def v2_manifest(output_path=None):
    manifest = v1_manifest(output_path)
    manifest["schemaVersion"] = 2
    manifest["id"] = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    manifest["captureIntegrity"] = {
        "status": "complete",
        "details": [],
        "diagnostics": ["+0.1s configurado: Microfone Externo (USB) 48000 Hz/1 canal"],
        "integrity": {
            "ruleVersion": 2,
            "sessionDurationS": 1800.0,
            "tracks": {
                "mic": {"startDelayS": 6.7, "trailingS": 0.2, "gapsS": 0.0, "lossS": 6.7,
                        "intervals": [{"kind": "start", "atS": 0.0, "durS": 6.7}]},
                "system": {"startDelayS": 0.3, "trailingS": 0.0, "gapsS": 0.0, "lossS": 0.0, "intervals": []},
            },
        },
    }
    manifest["record"] = {
        "appVersion": "1.8.0",
        "appBuild": "42",
        "pipelineVersion": "0.10.0",
        "pipelineGitSha": "abc1234",
        "pipelineDirty": True,
        "recordingStartedAt": "2026-10-02T12:00:00Z",
        "recordingStoppedAt": "2026-10-02T12:30:00Z",
        "stopReason": "user",
        "inputDevice": "AirPods de Fulano",
        "asrAttempts": [
            {"startedAt": "2026-10-02T12:30:00Z", "endedAt": "2026-10-02T12:40:00Z",
             "exitCode": 0, "pausedSeconds": 120.0, "overlappedRecording": True},
        ],
    }
    return manifest


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.sessions = self.tmp / "Sessions"
        self.sessions.mkdir()

    def write_session(self, name, manifest):
        folder = self.sessions / name
        folder.mkdir()
        (folder / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def write_transcript(self, stem, pipeline_version, turns, chunks=(), analysis=True):
        meta = {"type": "meta", "title": SECRET_TITLE, "pipeline_version": pipeline_version,
                "audio_duration_ms": 900000, "duration_ms": 880000}
        suffix = ".analysis.jsonl" if analysis else ".jsonl"
        rows = [meta] + [dict(type="turn", **turn) for turn in turns] + [dict(type="chunk", **c) for c in chunks]
        path = self.tmp / (stem + suffix)
        path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n", encoding="utf-8")
        return str(self.tmp / (stem + ".md"))

    def run_report(self, *extra):
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            code = report.main(["--sessions-dir", str(self.sessions), *extra])
        return code, stdout.getvalue()

    def rows(self, output):
        csv_part = output.split("\n\n", 1)[0]
        return list(csv.DictReader(io.StringIO(csv_part)))

    def test_v1_manifest_prints_nd_for_missing_fields(self):
        self.write_session("a", v1_manifest())
        code, output = self.run_report()

        self.assertEqual(code, 0)
        row = self.rows(output)[0]
        self.assertEqual(row["schema"], "1")
        self.assertEqual(row["session"], "11111111")
        for column in ("app_version", "loss_mic_s", "loss_system_s", "first_signal_mic_s",
                       "first_signal_system_s", "echo_pct", "untranscribed_blocks",
                       "asr_overlapped", "pipeline_dirty", "duration_s", "rtf", "device", "rearms"):
            self.assertEqual(row[column], "n/d", column)
        self.assertEqual(row["label"], "degraded")
        self.assertIn("Sessões: 1 (manifest v2: 0)", output)

    def test_v1_diary_and_old_transcript_are_measured(self):
        turns = [
            {"speaker": "Interlocutor", "text": "o relatório sai amanhã cedo para todos", "start_ms": 10000, "end_ms": 13000},
            {"speaker": "Você", "text": "o relatório sai amanhã cedo para todos", "start_ms": 10500, "end_ms": 13500},
            {"speaker": "Você", "text": "vamos alinhar o prazo com o time de dados", "start_ms": 20000, "end_ms": 24000},
            {"speaker": "Você", "text": "com o time de dados e depois seguimos", "start_ms": 24500, "end_ms": 27000},
        ]
        output_path = self.write_transcript("old", "0.9.1", turns, analysis=False)
        diary = [
            "+0.2s configurado: Fone de Fulano (Bluetooth) 16000 Hz/1 canal",
            "+6.7s áudio com sinal chegando",
            "+30.0s rearme (troca de rota), tentativa 1; engine rodando=false",
            "+31.0s rearme recente; o watchdog decide a próxima tentativa",
            "+40.0s rearme (troca de rota), tentativa 2; engine rodando=true",
            "+41.0s rearme recente; o watchdog decide a próxima tentativa",
        ]
        self.write_session("a", v1_manifest(output_path, diary))

        _, output = self.run_report()
        row = self.rows(output)[0]

        self.assertEqual(row["first_signal_mic_s"], "6.70")
        self.assertEqual(row["rearms"], "2")
        self.assertEqual(row["rearm_blocked_stopped"], "1")
        self.assertEqual(row["device"], "Fone de <nome>")
        self.assertEqual(row["duration_s"], "900.00")
        self.assertEqual(row["duration_source"], "audio")
        self.assertEqual(row["rtf"], "1.00")   # 15 min de job / 15 min de áudio
        self.assertEqual(row["echo_pct"], "29.17")   # 7 de 24 palavras do mic
        self.assertEqual(row["seam_dup_pairs"], "1")
        self.assertEqual(row["untranscribed_blocks"], "n/d")   # 0.9.1 não registra
        self.assertEqual(row["pipeline_version"], "0.9.1")

    def test_v2_manifest_fields(self):
        output_path = self.write_transcript(
            "new", "0.10.0",
            [{"speaker": "Você", "track": "mic", "text": "bom dia", "start_ms": 0, "end_ms": 1000}],
            chunks=[{"index": 0, "skipped_reason": "empty_asr"}, {"index": 1}, {"index": 2, "skipped_reason": "low_energy"}],
        )
        self.write_session("b", v2_manifest(output_path))

        _, output = self.run_report()
        row = self.rows(output)[0]

        self.assertEqual(row["schema"], "2")
        self.assertEqual((row["app_version"], row["version_source"]), ("1.8.0", "manifest"))
        self.assertEqual(row["duration_s"], "1800.00")
        self.assertEqual(row["duration_source"], "integrity")
        self.assertEqual((row["first_signal_mic_s"], row["first_signal_system_s"]), ("6.70", "0.30"))
        self.assertEqual((row["loss_mic_s"], row["loss_system_s"]), ("6.70", "0.00"))
        self.assertEqual(row["device"], "AirPods de <nome>")
        self.assertEqual(row["rtf"], "0.27")   # (600 s − 120 s pausados) / 1800 s
        self.assertEqual(row["asr_overlapped"], "sim")
        self.assertEqual(row["pipeline_dirty"], "sim")
        self.assertEqual(row["untranscribed_blocks"], "1")
        self.assertEqual(row["echo_pct"], "n/d")   # só trilha do mic: eco não se aplica

    def test_summary_groups_by_version_and_counts_silent_loss(self):
        self.write_session("b", v2_manifest())   # 6,7 s de perda no início, rótulo complete
        self.write_session("a", v1_manifest())
        _, output = self.run_report()

        line = next(l for l in output.splitlines() if l.startswith("1.8.0 |"))
        cells = [c.strip() for c in line.split("|")]
        self.assertEqual(cells[1:7], ["1", "1", "0/1", "1/1", "1/1", "0/1"])
        self.assertTrue(any(l.startswith("n/d |") for l in output.splitlines()))

    def test_version_is_inferred_from_release_dates(self):
        releases = report.parse_releases([
            "2026-09-25T19:31:03-03:00 v1.5.0",
            "2026-10-01T19:26:49-03:00 v1.6.0",
            "lixo",
        ])
        self.assertEqual(report.infer_version(datetime(2026, 10, 2, tzinfo=timezone.utc), releases), "1.6.0")
        self.assertIsNone(report.infer_version(datetime(2026, 9, 1, tzinfo=timezone.utc), releases))
        row = report.session_row(v1_manifest(), releases)
        self.assertEqual((row["app_version"], row["version_source"]), ("1.6.0", "inferida"))

    def test_never_prints_titles_speech_or_output_paths(self):
        output_path = self.write_transcript(
            "reuniao-confidencial", "0.10.0",
            [{"speaker": "Você", "track": "mic", "text": SECRET_SPEECH, "start_ms": 0, "end_ms": 3000}],
        )
        self.write_session("b", v2_manifest(output_path))
        self.write_session("a", v1_manifest(output_path))
        out_file = self.tmp / "out.csv"
        _, output = self.run_report("--out", str(out_file))

        everything = output + out_file.read_text(encoding="utf-8")
        for secret in (SECRET_TITLE, "secreta", "confidencial", "Fulano", str(self.tmp)):
            self.assertNotIn(secret, everything)
        self.assertEqual(len(list(csv.DictReader(io.StringIO(out_file.read_text(encoding="utf-8"))))), 2)
        self.assertNotIn("session,date", output)   # com --out, o CSV não vai ao stdout

    def test_unreadable_manifest_is_counted_not_fatal(self):
        folder = self.sessions / "broken"
        folder.mkdir()
        (folder / "manifest.json").write_text("{nao é json", encoding="utf-8")
        self.write_session("a", v1_manifest())
        code, output = self.run_report()
        self.assertEqual(code, 0)
        self.assertIn("Manifests ilegíveis ignorados: 1", output)

    def test_missing_sessions_dir_exits_two(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(report.main(["--sessions-dir", str(self.tmp / "nada")]), 2)

    def test_mask_device(self):
        self.assertEqual(report.mask_device("Fulano's AirPods Pro"), "<nome>'s AirPods Pro")
        self.assertEqual(report.mask_device("MacBook Air Microphone"), "MacBook Air Microphone")
        self.assertEqual(report.mask_device({"name": "iPhone do Fulano", "uid": "x"}), "iPhone do <nome>")
        self.assertIsNone(report.mask_device(""))


if __name__ == "__main__":
    unittest.main()
