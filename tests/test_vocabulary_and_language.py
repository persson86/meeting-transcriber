import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import transcribe_meeting as tm


def write_wav(test, duration_sec=12.0, amplitude=1000):
    samples = np.full(int(duration_sec * tm.SAMPLE_RATE), amplitude, dtype=np.int16)
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    wavfile.write(tmp.name, tm.SAMPLE_RATE, samples)
    test.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
    return tmp.name


class DetectingModel:
    """Modelo falso: detecta idioma por trecho e registra as chamadas."""

    def __init__(self, languages):
        self.languages = list(languages)
        self.detect_calls = 0
        self.calls = []

    def detect_language(self, audio_chunk):
        self.detect_calls += 1
        return self.languages.pop(0) if self.languages else "pt"

    def transcribe(self, audio_input, **kwargs):
        self.calls.append(kwargs)
        duration = len(audio_input) / tm.SAMPLE_RATE
        # Um segmento cobrindo o trecho inteiro: sem acionar o guarda de cobertura.
        return [
            SimpleNamespace(start=0.0, end=duration, text=" OAT e GOAT ", avg_logprob=-0.2, no_speech_prob=0.1)
        ], SimpleNamespace(duration=duration, language="pt", language_probability=0.9)


class ReplacementBoundaryTests(unittest.TestCase):
    def test_replacements_only_match_whole_words(self):
        replacements = {"OAT": "UAT", "Atlas Hab": "Atlas Hub"}

        text = tm.apply_text_replacements("OAT, GOAT, OATs e Atlas Hab; Atlas Habs", replacements)

        self.assertEqual(text, "UAT, GOAT, OATs e Atlas Hub; Atlas Habs")

    def test_replacements_keep_unicode_word_boundaries(self):
        text = tm.apply_text_replacements("ação Ação reação", {"ação": "acao"})

        self.assertEqual(text, "acao Ação reação")


class VocabularyTests(unittest.TestCase):
    def write_json(self, payload, raw=None):
        tmp = tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False, encoding="utf-8")
        tmp.write(raw if raw is not None else json.dumps(payload, ensure_ascii=False))
        tmp.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return tmp.name

    def test_load_vocabulary_dedupes_terms_and_keeps_explicit_replacements(self):
        path = self.write_json({
            "version": 1,
            "terms": ["Atlas Hub", " atlas hub ", "Design Review", ""],
            "replacements": {"Atlas Hab": "Atlas Hub", "ab": "curto demais"},
        })

        terms, replacements = tm.load_vocabulary(path)

        self.assertEqual(terms, ["Atlas Hub", "Design Review"])
        self.assertEqual(replacements, {"Atlas Hab": "Atlas Hub"})

    def test_load_vocabulary_rejects_invalid_files(self):
        cases = [
            self.write_json(None, raw="{not json"),
            self.write_json(["lista"]),
            self.write_json({"terms": "texto"}),
            self.write_json({"terms": [1, 2]}),
            self.write_json({"replacements": {"a b c": 3}}),
        ]
        for path in cases:
            with self.assertRaises(tm.VocabularyError):
                tm.load_vocabulary(path)
        with self.assertRaises(tm.VocabularyError):
            tm.load_vocabulary("/nonexistent/vocabulary.json")

    def test_load_vocabulary_rejects_oversized_file(self):
        path = self.write_json({"terms": ["x" * 50] * 2000})

        with self.assertRaises(tm.VocabularyError):
            tm.load_vocabulary(path)

    def test_vocabulary_terms_reach_the_prompt_tail(self):
        config = tm.TranscriptionConfig(language="pt", glossary=["Atlas Hub", "Design Review"])

        kwargs = tm.transcription_kwargs(config, vad_filter=False)

        self.assertIn("Termos: Atlas Hub, Design Review.", kwargs["hotwords"])


class LanguageLockTests(unittest.TestCase):
    def islands(self):
        sr = tm.SAMPLE_RATE
        # Um trecho longo e dois curtos: só o longo deve pesar na decisão.
        return [
            {"start": 0, "end": int(0.8 * sr)},
            {"start": 4 * sr, "end": int(4.6 * sr)},
            {"start": 6 * sr, "end": 11 * sr},
        ]

    def test_auto_locks_language_once_per_track_and_uses_its_profile(self):
        wav_path = write_wav(self)
        model = DetectingModel(["pt"])
        config = tm.TranscriptionConfig(language="auto", glossary=["Atlas Hub"])
        report = {}

        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            segments = tm.transcribe_track(
                wav_path, "Você", model, config=config, language_report=report,
            )

        self.assertEqual(report["detected"], "pt")
        self.assertEqual(model.detect_calls, 1)   # só o trecho ≥ 2 s vota
        self.assertTrue(model.calls)
        for call in model.calls:
            self.assertEqual(call["language"], "pt")
            self.assertIn("Reunião de trabalho em português brasileiro.", call["initial_prompt"])
            self.assertIn("Termos: Atlas Hub.", call["hotwords"])
        # Correções padrão do português passam a valer, com fronteira de palavra.
        self.assertTrue(all(segment.text == "UAT e GOAT" for segment in segments))
        self.assertEqual(config.language, "auto")   # a config do chamador não muda

    def test_auto_vote_weights_long_chunks(self):
        sr = tm.SAMPLE_RATE
        audio = np.full(20 * sr, 0.1, dtype=np.float32)
        chunks = [
            {"start": 0, "end": 3 * sr},        # 3 s → "en"
            {"start": 4 * sr, "end": 16 * sr},  # 12 s → "pt"
            {"start": 17 * sr, "end": 20 * sr}, # 3 s → "en"
        ]
        model = DetectingModel(["pt", "en", "en"])   # ordem: maiores primeiro

        language, votes = tm.detect_track_language(model, audio, chunks)

        self.assertEqual(language, "pt")
        self.assertEqual(votes, {"pt": 12.0, "en": 6.0})

    def test_detection_falls_back_to_transcribe_when_backend_has_no_detector(self):
        sr = tm.SAMPLE_RATE
        audio = np.full(10 * sr, 0.1, dtype=np.float32)

        class PlainModel:
            def __init__(self):
                self.calls = []

            def transcribe(self, audio_input, **kwargs):
                self.calls.append(kwargs)
                return [], SimpleNamespace(language="en", language_probability=0.8)

        model = PlainModel()
        language, _ = tm.detect_track_language(model, audio, [{"start": 0, "end": 10 * sr}])

        self.assertEqual(language, "en")
        self.assertIsNone(model.calls[0]["language"])
        self.assertIsNone(model.calls[0]["initial_prompt"])

    def test_detection_failure_keeps_auto_behavior(self):
        wav_path = write_wav(self)

        class FailingDetector(DetectingModel):
            def detect_language(self, audio_chunk):
                raise RuntimeError("boom")

        model = FailingDetector([])
        report = {}
        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            tm.transcribe_track(wav_path, "Você", model, config=tm.TranscriptionConfig(language="auto"), language_report=report)

        self.assertIsNone(report["detected"])
        self.assertTrue(all(call["language"] is None for call in model.calls))

    def test_unknown_detected_language_decodes_without_portuguese_profile(self):
        cfg = tm.get_lang_config("es")

        self.assertEqual(cfg["whisper_lang"], "es")
        self.assertIsNone(cfg["base_prompt"])
        self.assertEqual(tm.default_hotwords_for_language("es"), [])

    def test_config_for_language_keeps_explicit_replacements_over_defaults(self):
        config = tm.TranscriptionConfig(language="auto", replacements={"OAT": "OAT-explicito"})

        locked = tm.config_for_language(config, "pt")

        self.assertEqual(locked.replacements["OAT"], "OAT-explicito")
        self.assertEqual(locked.replacements["SandPoint"], "endpoint")
        self.assertEqual(config.replacements, {"OAT": "OAT-explicito"})


class DateAndNamingTests(unittest.TestCase):
    def setUp(self):
        self._tz = os.environ.get("TZ")
        os.environ["TZ"] = "America/Sao_Paulo"
        time.tzset()

    def tearDown(self):
        if self._tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self._tz
        time.tzset()

    def test_local_datetime_converts_utc_to_local_offset(self):
        value = tm.local_datetime("2026-09-23T12:10:31Z")

        self.assertEqual(value.isoformat(timespec="seconds"), "2026-09-23T09:10:31-03:00")
        self.assertEqual(tm.format_local_datetime(value), "2026-09-23 09:10 (UTC-03:00)")
        self.assertIsNone(tm.local_datetime("não é data"))

    def test_explicit_offset_is_preserved_regardless_of_machine_timezone(self):
        for tz in ("UTC", "America/Sao_Paulo", "Asia/Tokyo"):
            os.environ["TZ"] = tz
            time.tzset()
            value = tm.local_datetime("2026-09-10T09:00:00-03:00")
            self.assertEqual(value.isoformat(timespec="seconds"), "2026-09-10T09:00:00-03:00", tz)

    def test_output_stem_uses_recording_start_not_processing_time(self):
        stem = tm.output_stem(
            "Reunião 2026-09-22 16:18",
            recorded_at="2026-09-23T11:05:00Z",
            session_id="C68054A5-1111-2222-3333-444455556666",
            now=datetime(2026, 9, 24, 7, 0),
        )

        self.assertEqual(stem, "2026-09-23_08-05_reuniao-2026-09-22-1618-C68054A5")

    def test_slugify_is_ascii_for_nfc_and_nfd_titles(self):
        nfc = "Reunião de apresentação"
        nfd = "Reunião de apresentação"

        self.assertEqual(tm.slugify(nfc), "reuniao-de-apresentacao")
        self.assertEqual(tm.slugify(nfd), "reuniao-de-apresentacao")

    def test_meta_and_markdown_use_local_time_and_expected_attendees(self):
        turns = [tm.Turn(speaker="Você", text="Oi", start_ms=0, end_ms=1000, confidence=0.9, is_suspect=False)]
        event = {
            "title": "Checkpoint",
            "start": "2026-09-23T09:00:00-03:00",
            "end": "2026-09-23T09:30:00-03:00",
            "attendees_expected": ["Ana", "Bruno"],
            "source": "calendar_selection",
        }

        meta = tm.build_meeting_meta(
            title="Checkpoint — 2026-09-23 09:00",
            language="auto",
            turns=turns,
            tracks="both",
            backend="mlx",
            model_name="m",
            recorded_at="2026-09-23T12:01:00Z",
            language_detected={"mic": "pt", "system": "pt"},
            calendar_event=event,
            audio_duration_ms=61000,
        )
        markdown = tm.build_markdown(
            "Checkpoint — 2026-09-23 09:00", turns, True, "auto",
            recorded_at="2026-09-23T12:01:00Z",
            language_detected={"mic": "pt", "system": "pt"},
            calendar_event=event,
        )

        self.assertEqual(meta["date"], "2026-09-23T09:01:00-03:00")
        self.assertEqual(meta["language_detected"], {"mic": "pt", "system": "pt"})
        self.assertEqual(meta["calendar_event"]["attendees_expected"], ["Ana", "Bruno"])
        self.assertEqual(meta["audio_duration_ms"], 61000)
        self.assertIn("**Data:** 2026-09-23 09:01 (UTC-03:00)", markdown)
        self.assertNotIn("12:01:00Z", markdown)
        self.assertIn("**Idioma:** auto-detect (mic pt, system pt)", markdown)
        self.assertIn("**Evento do Calendar:** Checkpoint (09:00–09:30)", markdown)
        self.assertIn("Convidados (convite, não confirma presença):** Ana, Bruno", markdown)


if __name__ == "__main__":
    unittest.main()


class CoverageGuardTests(unittest.TestCase):
    def islands(self):
        sr = tm.SAMPLE_RATE
        return [{"start": 0, "end": 20 * sr}]

    def model(self, short_with_vocabulary):
        class CoverageModel:
            def __init__(self):
                self.calls = []

            def transcribe(self, audio_input, **kwargs):
                self.calls.append(kwargs)
                duration = len(audio_input) / tm.SAMPLE_RATE
                if kwargs.get("hotwords") and short_with_vocabulary:
                    # Whisper "pulou" quase todo o bloco com o prompt longo.
                    segments = [SimpleNamespace(start=0.0, end=3.0, text=" só o começo ", avg_logprob=-0.2, no_speech_prob=0.1)]
                else:
                    segments = [
                        SimpleNamespace(start=0.0, end=9.0, text=" primeira parte inteira ", avg_logprob=-0.2, no_speech_prob=0.1),
                        SimpleNamespace(start=9.5, end=19.5, text=" segunda parte inteira ", avg_logprob=-0.2, no_speech_prob=0.1),
                    ]
                return segments, SimpleNamespace(duration=duration, language="pt", language_probability=0.9)
        return CoverageModel()

    def test_low_coverage_chunk_is_retried_without_vocabulary(self):
        wav_path = write_wav(self, duration_sec=21.0)
        model = self.model(short_with_vocabulary=True)
        report = {}
        config = tm.TranscriptionConfig(language="pt", glossary=["Atlas Hub"])

        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            segments = tm.transcribe_track(wav_path, "Você", model, config=config, quality_report=report)

        self.assertEqual(len(model.calls), 2)
        self.assertIn("Termos: Atlas Hub.", model.calls[0]["hotwords"])
        self.assertIsNone(model.calls[1]["hotwords"])
        self.assertEqual([seg.text for seg in segments], ["primeira parte inteira", "segunda parte inteira"])
        self.assertEqual(report, {"coverage_retries": 1, "coverage_retries_used": 1})

    def test_chunk_log_records_adopted_retry_without_changing_text(self):
        wav_path = write_wav(self, duration_sec=21.0)
        model = self.model(short_with_vocabulary=True)
        chunk_log = []
        config = tm.TranscriptionConfig(language="pt", glossary=["Atlas Hub"])

        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            segments = tm.transcribe_track(
                wav_path, "Interlocutor", model, config=config, offset_sec=0.2, chunk_log=chunk_log,
            )

        self.assertEqual([seg.text for seg in segments], ["primeira parte inteira", "segunda parte inteira"])
        self.assertEqual(len(chunk_log), 1)
        entry = chunk_log[0]
        self.assertEqual((entry["index"], entry["start_ms"], entry["end_ms"]), (1, 200, 20200))
        # O texto adotado veio da retranscrição, que roda sem vocabulário.
        self.assertFalse(entry["hotwords"])
        self.assertTrue(entry["coverage_retry"]["used"])
        self.assertEqual(entry["coverage_retry"]["covered_ms"], 3000)
        self.assertEqual(entry["coverage_retry"]["retry_covered_ms"], 19000)
        self.assertEqual(entry["segments"], 2)
        self.assertNotIn("text", json.dumps(entry))

    def test_chunk_log_is_json_serializable_with_numpy_values(self):
        # O decoder real devolve tempos numpy; a decisão do retry vira numpy.bool_.
        wav_path = write_wav(self, duration_sec=21.0)

        class NumpyModel:
            def transcribe(self, audio_input, **kwargs):
                duration = len(audio_input) / tm.SAMPLE_RATE
                end = np.float32(3.0) if kwargs.get("hotwords") else np.float32(19.5)
                segments = [SimpleNamespace(start=np.float32(0.0), end=end, text=" parte ", avg_logprob=-0.2, no_speech_prob=0.1)]
                return segments, SimpleNamespace(duration=duration, language="pt", language_probability=0.9)

        chunk_log = []
        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            tm.transcribe_track(
                wav_path, "Você", NumpyModel(),
                config=tm.TranscriptionConfig(language="pt", glossary=["X"]), chunk_log=chunk_log,
            )

        self.assertIs(chunk_log[0]["coverage_retry"]["used"], True)
        json.dumps(chunk_log)

    def test_chunk_log_marks_vocabulary_when_no_retry(self):
        wav_path = write_wav(self, duration_sec=21.0)
        model = self.model(short_with_vocabulary=False)
        chunk_log = []

        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            tm.transcribe_track(
                wav_path, "Você", model,
                config=tm.TranscriptionConfig(language="pt", glossary=["X"]), chunk_log=chunk_log,
            )

        self.assertTrue(chunk_log[0]["hotwords"])
        self.assertNotIn("coverage_retry", chunk_log[0])

    def test_good_coverage_chunk_is_not_retried(self):
        wav_path = write_wav(self, duration_sec=21.0)
        model = self.model(short_with_vocabulary=False)
        report = {}

        with patch.object(tm, "detect_speech_islands", return_value=self.islands()):
            tm.transcribe_track(wav_path, "Você", model, config=tm.TranscriptionConfig(language="pt", glossary=["X"]), quality_report=report)

        self.assertEqual(len(model.calls), 1)
        self.assertEqual(report, {})

    def test_covered_seconds_merges_overlapping_segments(self):
        segments = [
            tm.Segment(start=0.0, end=4.0, text="a", speaker="Você"),
            tm.Segment(start=3.0, end=6.0, text="b", speaker="Você"),
            tm.Segment(start=8.0, end=12.0, text="c", speaker="Você"),
        ]

        self.assertAlmostEqual(tm.covered_seconds(segments, 0.0, 10.0), 8.0)
        self.assertAlmostEqual(
            tm.speech_seconds_in_range([{"start": 0, "end": 16000}, {"start": 32000, "end": 64000}], 16000, 48000),
            1.0,
        )
