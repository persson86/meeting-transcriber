import json
import sys
import unittest
import wave
from pathlib import Path


FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "audio-baselines"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_quality_baselines import MAX_TURN_MS, compute_stats, load_turns  # noqa: E402


def wav_metadata(path):
    with wave.open(str(path), "rb") as wav:
        frames = wav.getnframes()
        sample_rate = wav.getframerate()
        return {
            "channels": wav.getnchannels(),
            "sample_width_bytes": wav.getsampwidth(),
            "sample_rate_hz": sample_rate,
            "frames": frames,
            "duration_sec": round(frames / sample_rate, 3),
        }


@unittest.skipUnless(
    MANIFEST_PATH.exists(),
    "corpus local de áudio ausente; execute make test-asr em um ambiente provisionado",
)
class AudioBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_manifest_lists_every_baseline_directory(self):
        manifest_ids = sorted(case["id"] for case in self.manifest["cases"])
        fixture_ids = sorted(path.name for path in FIXTURE_ROOT.iterdir() if path.is_dir())

        self.assertEqual(manifest_ids, fixture_ids)

    def test_primary_regression_cases_are_marked(self):
        primary_ids = {
            case["id"]
            for case in self.manifest["cases"]
            if case["role"] == "primary-regression"
        }

        self.assertEqual(
            primary_ids,
            {
                "meeting-1780593880",
                "meeting-1780597060-real-meet-1522",
            },
        )

    def test_audio_files_match_manifest_metadata(self):
        for case in self.manifest["cases"]:
            with self.subTest(case=case["id"]):
                case_dir = FIXTURE_ROOT / case["id"]
                actual_tracks = sorted(path.name for path in case_dir.glob("*.wav"))
                expected_tracks = sorted(track["file"] for track in case["tracks"].values())
                self.assertEqual(actual_tracks, expected_tracks)

                durations = []
                for track_name, expected in case["tracks"].items():
                    path = case_dir / expected["file"]
                    actual = wav_metadata(path)
                    durations.append(actual["duration_sec"])

                    self.assertEqual(actual["channels"], expected["channels"], track_name)
                    self.assertEqual(
                        actual["sample_width_bytes"],
                        expected["sample_width_bytes"],
                        track_name,
                    )
                    self.assertEqual(
                        actual["sample_rate_hz"],
                        expected["sample_rate_hz"],
                        track_name,
                    )
                    self.assertEqual(actual["frames"], expected["frames"], track_name)
                    self.assertAlmostEqual(
                        actual["duration_sec"],
                        expected["duration_sec"],
                        places=3,
                        msg=track_name,
                    )

                self.assertLessEqual(
                    max(durations) - min(durations),
                    case["max_track_duration_delta_sec"],
                )

    def test_approved_goldens_are_free_of_pathologies(self):
        """Golden aprovado não pode conter runaway, turnos > 30s ou JSONL inválido.

        Não transcreve nada — só valida os golden.jsonl existentes. A comparação
        transcrição-vs-golden roda via tests/run_quality_baselines.py (make baselines).
        """
        goldens = sorted(FIXTURE_ROOT.glob("*/golden.jsonl"))
        if not goldens:
            self.skipTest("nenhum golden.jsonl aprovado ainda (make baselines-update)")

        for golden_path in goldens:
            with self.subTest(golden=golden_path.parent.name):
                turns = load_turns(golden_path)
                self.assertGreater(len(turns), 0)
                stats = compute_stats(turns)
                self.assertEqual(stats.runaway_turns, [])
                self.assertLessEqual(stats.max_turn_ms, MAX_TURN_MS)


if __name__ == "__main__":
    unittest.main()
