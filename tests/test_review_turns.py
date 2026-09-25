import io
import json
import sys
import tempfile
import unittest
import wave
from array import array
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import review_turns as rt

RATE = 16_000


def write_marked_wav(path: Path, seconds: int) -> None:
    """Cada segundo do arquivo tem amostras iguais ao número do segundo: o
    primeiro valor de um clipe revela de que ponto do WAV ele saiu."""
    samples = array("h")
    for second in range(seconds):
        samples.extend([second] * RATE)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(samples.tobytes())


def first_sample(path: Path) -> int:
    with wave.open(str(path), "rb") as clip:
        return array("h", clip.readframes(1))[0]


class ReviewTurnsTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.clips = self.dir / "clips"
        patcher = patch.object(rt, "CLIP_DIR", self.clips)
        patcher.start()
        self.addCleanup(patcher.stop)
        support = patch.object(rt, "APP_SUPPORT", self.dir / "support")
        support.start()
        self.addCleanup(support.stop)

    def write_transcript(self, rows, name="reuniao.jsonl"):
        path = self.dir / name
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
        return path

    def session(self, sys_offset_ms=0.0, meta_offsets=None):
        audio = self.dir / "audio"
        audio.mkdir()
        write_marked_wav(audio / "mic.wav", 60)
        write_marked_wav(audio / "system.wav", 60)
        (audio / "metadata.json").write_text(json.dumps({"sysOffsetMs": sys_offset_ms}))
        meta = {"type": "meta", "session_id": "9F3A2C10-1B2D-4E5F-8A9B-0C1D2E3F4A5B"}
        if meta_offsets is not None:
            meta["track_offsets_ms"] = meta_offsets
        return audio, meta

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = rt.main([str(a) for a in argv])
        return code, out.getvalue(), err.getvalue()

    def clip_paths(self):
        return sorted(self.clips.glob("*.wav"))

    def test_clip_uses_track_offset_and_margin(self):
        audio, meta = self.session(sys_offset_ms=2000.0)
        path = self.write_transcript([
            meta,
            {"type": "turn", "speaker": "Interlocutor", "text": "x", "start_ms": 20_000, "end_ms": 25_000,
             "confidence": 0.9, "is_suspect": False},
        ])

        code, out, _ = self.run_cli(path, "--at", "0:20", "--audio-dir", audio, "--no-play")

        self.assertEqual(code, 0)
        [clip] = self.clip_paths()
        # Sessão 18 s (20 s − 2 s de margem) → WAV do sistema em 16 s (offset de 2 s).
        self.assertEqual(first_sample(clip), 16)
        self.assertIn("system", clip.name)
        self.assertIn("Trilha inferida", out)

    def test_offsets_recorded_in_transcript_win_over_session_metadata(self):
        audio, meta = self.session(sys_offset_ms=9000.0, meta_offsets={"mic": 0.0, "system": 1000.0})
        path = self.write_transcript([
            meta,
            {"type": "turn", "speaker": "Interlocutor", "track": "system", "text": "x",
             "start_ms": 30_000, "end_ms": 31_000, "confidence": 0.9, "is_suspect": False},
        ])

        self.run_cli(path, "--at", "30", "--audio-dir", audio, "--no-play", "--margin", "0")

        self.assertEqual(first_sample(self.clip_paths()[0]), 29)

    def test_markdown_timestamp_selects_turn_by_its_header(self):
        path = self.write_transcript([
            {"type": "meta"},
            {"type": "turn", "speaker": "Interlocutor", "text": "anterior", "start_ms": 5_000, "end_ms": 10_900,
             "confidence": 0.9, "is_suspect": False},
            {"type": "turn", "speaker": "Interlocutor", "text": "alvo", "start_ms": 10_722, "end_ms": 20_000,
             "confidence": 0.9, "is_suspect": False},
        ])
        meta, turns, _ = rt.load(path)

        chosen = rt.select_turns(turns, rt.parse_time("0:10"), None)

        self.assertEqual([t["text"] for t in chosen], ["alvo"])

    def test_simultaneous_tracks_both_selected_without_track_filter(self):
        rows = [
            {"type": "turn", "speaker": "Você", "text": "a", "start_ms": 1_000, "end_ms": 9_000, "confidence": 0.9, "is_suspect": False},
            {"type": "turn", "speaker": "Interlocutor", "text": "b", "start_ms": 3_000, "end_ms": 8_000, "confidence": 0.9, "is_suspect": False},
        ]
        _, turns, _ = rt.load(self.write_transcript(rows))

        self.assertEqual(len(rt.select_turns(turns, 5_000, None)), 2)
        self.assertEqual([t["track"] for t in rt.select_turns(turns, 5_000, "mic")], ["mic"])

    def test_single_track_session_plays_the_only_track(self):
        audio = self.dir / "audio"
        audio.mkdir()
        write_marked_wav(audio / "mic.wav", 30)
        path = self.write_transcript([
            {"type": "meta", "tracks": "mic"},
            {"type": "turn", "speaker": "Áudio", "text": "x", "start_ms": 10_000, "end_ms": 12_000,
             "confidence": 0.9, "is_suspect": False},
        ])

        code, _, _ = self.run_cli(path, "--at", "0:10", "--track", "mic", "--audio-dir", audio, "--no-play", "--margin", "0")

        self.assertEqual(code, 0)
        self.assertEqual(first_sample(self.clip_paths()[0]), 10)

    def test_unknown_track_uses_the_only_wav_found(self):
        audio = self.dir / "audio"
        audio.mkdir()
        write_marked_wav(audio / "mic.wav", 30)
        path = self.write_transcript([
            {"type": "meta"},
            {"type": "turn", "speaker": "Felipe", "text": "x", "start_ms": 5_000, "end_ms": 6_000,
             "confidence": 0.9, "is_suspect": False},
        ])

        code, out, _ = self.run_cli(path, "--at", "0:05", "--audio-dir", audio, "--no-play", "--margin", "0")

        self.assertEqual(code, 0)
        self.assertIn("único áudio", out)

    def test_missing_audio_fails_without_claiming_review(self):
        path = self.write_transcript([
            {"type": "meta", "session_id": "00000000-0000-0000-0000-000000000000"},
            {"type": "turn", "speaker": "Você", "text": "x", "start_ms": 0, "end_ms": 1_000, "confidence": 0.9, "is_suspect": False},
        ])

        code, _, err = self.run_cli(path, "--at", "0:00", "--no-play")

        self.assertEqual(code, rt.EXIT_NO_AUDIO)
        self.assertIn("nada foi conferido no áudio", err)
        self.assertEqual(self.clip_paths(), [])

    def test_listing_uses_triage_flags_and_ignores_unclustered_remote(self):
        path = self.write_transcript([
            {"type": "meta"},
            {"type": "turn", "speaker": "Interlocutor", "track": "system", "text": "ok", "start_ms": 0, "end_ms": 1,
             "confidence": 0.9, "is_suspect": False, "quality_flags": ["remote_unclustered"]},
            {"type": "turn", "speaker": "Você", "text": "bruto", "raw_text": "brut0", "start_ms": 2, "end_ms": 3,
             "confidence": 0.9, "is_suspect": False},
            {"type": "turn", "speaker": "Você", "text": "baixa", "start_ms": 4, "end_ms": 5,
             "confidence": 0.4, "is_suspect": False},
        ], name="reuniao.analysis.jsonl")

        _, out, _ = self.run_cli(path)

        self.assertIn("2 de 3 turnos sinalizados", out)
        self.assertNotIn(" ok", out.split("\n\n")[0])

    def test_markdown_path_prefers_analysis_sibling(self):
        (self.dir / "r.md").write_text("# x")
        self.write_transcript([{"type": "meta"}], name="r.jsonl")
        analysis = self.write_transcript([{"type": "meta"}], name="r.analysis.jsonl")

        self.assertEqual(rt.resolve_transcript(self.dir / "r.md"), analysis)

    def test_range_requires_track_with_two_tracks(self):
        path = self.write_transcript([
            {"type": "turn", "speaker": "Você", "text": "a", "start_ms": 0, "end_ms": 1, "confidence": 0.9, "is_suspect": False},
            {"type": "turn", "speaker": "Interlocutor", "text": "b", "start_ms": 0, "end_ms": 1, "confidence": 0.9, "is_suspect": False},
        ])

        code, _, err = self.run_cli(path, "--range", "0:01-0:05", "--no-play")

        self.assertEqual(code, 2)
        self.assertIn("--track", err)

    def test_long_turn_clip_is_centered_on_requested_instant(self):
        self.assertEqual(rt.clip_window(0, 120_000, 60_000, 2_000, 40_000), (40_000, 80_000))
        self.assertEqual(rt.clip_window(10_000, 15_000, 12_000, 2_000, 40_000), (8_000, 17_000))

    def test_chunks_answer_where_a_turn_came_from(self):
        path = self.write_transcript([
            {"type": "meta"},
            {"type": "chunk", "track": "system", "index": 7, "start_ms": 40_000, "end_ms": 68_000,
             "slice_start_ms": 38_000, "hotwords": False, "prompt_tail_chars": 120,
             "coverage_retry": {"speech_ms": 20_000, "covered_ms": 4_000, "retry_covered_ms": 19_000, "used": True}},
            {"type": "chunk", "track": "system", "index": 8, "start_ms": 68_000, "end_ms": 90_000,
             "slice_start_ms": 66_000, "hotwords": True, "prompt_tail_chars": 80},
        ], name="c.analysis.jsonl")

        _, out, _ = self.run_cli(path, "--chunks", "--at", "0:50")

        self.assertIn("bloco 7", out)
        self.assertIn("retry de cobertura adotado", out)
        self.assertNotIn("bloco 8", out)


if __name__ == "__main__":
    unittest.main()
