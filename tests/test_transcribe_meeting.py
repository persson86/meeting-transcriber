import sys
import tempfile
import unittest
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import transcribe_meeting as tm


class FakeModel:
    def __init__(self):
        self.calls = []

    def transcribe(self, audio_input, **kwargs):
        self.calls.append((audio_input, kwargs))
        duration = len(audio_input) / tm.SAMPLE_RATE if isinstance(audio_input, np.ndarray) else 3.0
        raw_segments = [
            SimpleNamespace(start=0.05, end=0.30, text=" olá "),
            SimpleNamespace(start=0.40, end=0.50, text="."),
        ]
        info = SimpleNamespace(duration=duration, language="pt", language_probability=0.99)
        return raw_segments, info


class FakeParser:
    def __init__(self):
        self.message = None

    def error(self, message):
        self.message = message
        raise SystemExit(2)


class TranscribeMeetingTests(unittest.TestCase):
    def write_wav(self, duration_sec=3.0, amplitude=0):
        samples = np.full(int(duration_sec * tm.SAMPLE_RATE), amplitude, dtype=np.int16)
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        wavfile.write(tmp.name, tm.SAMPLE_RATE, samples)
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return tmp.name

    def test_emit_progress_clamps_and_only_emits_increases(self):
        tm._last_progress = -1

        with patch("builtins.print") as print_mock:
            tm.emit_progress(-5)
            tm.emit_progress(0)
            tm.emit_progress(17.9)
            tm.emit_progress(17)
            tm.emit_progress(101)

        self.assertEqual(
            [call.args[0] for call in print_mock.call_args_list],
            ["PROGRESS: 0", "PROGRESS: 17", "PROGRESS: 100"],
        )
        self.assertTrue(all(call.kwargs == {"flush": True} for call in print_mock.call_args_list))

    def test_audio_duration_sec_reads_wav_without_loading_samples(self):
        wav_path = self.write_wav(duration_sec=2.5)

        self.assertAlmostEqual(tm.audio_duration_sec(wav_path), 2.5)
        self.assertEqual(tm.audio_duration_sec(None), 0.0)
        self.assertEqual(tm.audio_duration_sec("/missing/audio.wav"), 0.0)

    def test_normalize_audio_downmixes_integer_channels_after_scaling(self):
        mono = np.array([1000, -1000], dtype=np.int16)
        stereo = np.column_stack([mono, mono])

        normalized_mono = tm.normalize_audio(mono)
        normalized_stereo = tm.normalize_audio(stereo)

        np.testing.assert_allclose(normalized_stereo, normalized_mono)
        self.assertLessEqual(float(np.max(np.abs(normalized_stereo))), 1.0)

    def test_transcribe_track_reports_chunk_progress_by_total_duration(self):
        wav_path = self.write_wav(duration_sec=3.0, amplitude=1000)
        model = FakeModel()

        with patch.object(
            tm,
            "detect_speech_islands",
            return_value=[{"start": tm.SAMPLE_RATE, "end": 2 * tm.SAMPLE_RATE}],
        ), patch.object(tm, "emit_progress") as emit:
            tm.transcribe_track(
                wav_path,
                "Você",
                model,
                chunk_by_silence=True,
                progress_base_sec=3.0,
                total_sec=10.0,
            )

        emit.assert_called_once_with(45.0)

    def test_transcribe_track_reports_full_track_progress(self):
        wav_path = self.write_wav(duration_sec=3.0)

        with patch.object(tm, "emit_progress") as emit:
            tm.transcribe_track(
                wav_path,
                "Você",
                FakeModel(),
                chunk_by_silence=False,
                progress_base_sec=2.0,
                total_sec=10.0,
            )

        emit.assert_called_once_with(45.0)

    def test_chunk_by_silence_restores_absolute_timestamps(self):
        wav_path = self.write_wav(amplitude=1000)
        model = FakeModel()

        with patch.object(
            tm,
            "detect_speech_islands",
            return_value=[{"start": tm.SAMPLE_RATE, "end": 2 * tm.SAMPLE_RATE}],
        ):
            segments = tm.transcribe_track(
                wav_path,
                "Você",
                model,
                offset_sec=0.25,
                chunk_by_silence=True,
            )

        self.assertEqual(len(segments), 1)
        self.assertAlmostEqual(segments[0].start, 1.30)
        self.assertAlmostEqual(segments[0].end, 1.55)
        self.assertEqual(segments[0].text, "olá")
        self.assertIsInstance(model.calls[0][0], np.ndarray)
        self.assertFalse(model.calls[0][1]["vad_filter"])

    def test_legacy_full_track_keeps_old_transcription_shape(self):
        wav_path = self.write_wav()
        model = FakeModel()

        segments = tm.transcribe_track(
            wav_path,
            "Interlocutor",
            model,
            offset_sec=0.10,
            chunk_by_silence=False,
        )

        self.assertEqual(len(segments), 1)
        self.assertAlmostEqual(segments[0].start, 0.15)
        self.assertEqual(model.calls[0][0], wav_path)
        self.assertTrue(model.calls[0][1]["vad_filter"])
        self.assertEqual(model.calls[0][1]["vad_parameters"], tm.VAD_PARAMETERS)

    def test_group_speech_islands_merges_nearby_context_only(self):
        islands = [
            {"start": 1 * tm.SAMPLE_RATE, "end": 2 * tm.SAMPLE_RATE},
            {"start": 3 * tm.SAMPLE_RATE, "end": 4 * tm.SAMPLE_RATE},
            {"start": 8 * tm.SAMPLE_RATE, "end": 9 * tm.SAMPLE_RATE},
        ]

        grouped = tm.group_speech_islands(islands)

        self.assertEqual(grouped, [
            {"start": 1 * tm.SAMPLE_RATE, "end": 4 * tm.SAMPLE_RATE, "overlap": False},
            {"start": 8 * tm.SAMPLE_RATE, "end": 9 * tm.SAMPLE_RATE, "overlap": False},
        ])

    def test_group_speech_islands_marks_span_splits_for_overlap(self):
        sr = tm.SAMPLE_RATE
        islands = [
            {"start": 0, "end": 20 * sr},
            # gap 1s (fala contínua) mas span mesclado 40s > 28s → corte artificial
            {"start": 21 * sr, "end": 40 * sr},
            # gap 10s > 3.5s → silêncio real, sem overlap
            {"start": 50 * sr, "end": 55 * sr},
        ]

        grouped = tm.group_speech_islands(islands)

        self.assertEqual([g["overlap"] for g in grouped], [False, True, False])
        self.assertEqual([g["start"] for g in grouped], [0, 21 * sr, 50 * sr])

    def test_drop_overlap_duplicates_discards_fully_covered_segments(self):
        segments = [
            tm.Segment(18.0, 19.0, "duplicado", "Você"),
            tm.Segment(19.6, 21.0, "novo", "Você"),
        ]

        kept = tm.drop_overlap_duplicates(segments, covered_until_sec=20.0)

        self.assertEqual([seg.text for seg in kept], ["novo"])

    def test_drop_overlap_duplicates_keeps_segment_straddling_the_seam(self):
        # Whisper pode emitir um único segmento longo cobrindo o chunk inteiro:
        # começa na janela coberta mas carrega conteúdo novo — não pode ser perdido.
        segments = [
            tm.Segment(17.5, 33.0, "segmento longo atravessando a costura", "Interlocutor"),
            tm.Segment(17.8, 19.9, "totalmente coberto", "Interlocutor"),
        ]

        kept = tm.drop_overlap_duplicates(segments, covered_until_sec=20.0)

        self.assertEqual(
            [seg.text for seg in kept],
            ["segmento longo atravessando a costura"],
        )

    def test_drop_overlap_duplicates_keeps_tiny_segment_after_boundary(self):
        segments = [
            tm.Segment(20.1, 20.4, "curto e novo", "Interlocutor"),
        ]

        kept = tm.drop_overlap_duplicates(segments, covered_until_sec=20.0)

        self.assertEqual([seg.text for seg in kept], ["curto e novo"])

    def test_transcribe_track_overlap_slices_back_and_dedups(self):
        sr = tm.SAMPLE_RATE
        wav_path = self.write_wav(duration_sec=31.0, amplitude=1000)

        class OverlapFakeModel:
            def __init__(self):
                self.calls = []

            def transcribe(self, audio_input, **kwargs):
                self.calls.append(audio_input)
                raw_segments = [
                    SimpleNamespace(start=0.1, end=0.5, text=" parte coberta "),
                    SimpleNamespace(start=2.6, end=3.0, text=" parte nova "),
                ]
                info = SimpleNamespace(duration=len(audio_input) / sr, language="pt", language_probability=0.99)
                return raw_segments, info

        islands = [
            {"start": 1 * sr, "end": 21 * sr},
            {"start": 22 * sr, "end": 30 * sr},   # gap 1s, span 29s > 28s → overlap
        ]

        model = OverlapFakeModel()
        with patch.object(tm, "detect_speech_islands", return_value=islands):
            segments = tm.transcribe_track(
                wav_path, "Você", model, chunk_by_silence=True, chunk_overlap=True,
            )

        # Chunk 2 fatiado de 19s (22 - 3 de overlap): primeiro segmento cai em
        # 19.1s — dentro da janela coberta pelo chunk 1 (até 21s) → descartado.
        self.assertEqual(len(model.calls), 2)
        self.assertEqual(len(model.calls[1]), (30 - 19) * sr)
        starts = [round(seg.start, 2) for seg in segments]
        self.assertEqual(starts, [1.1, 3.6, 21.6])

    def test_transcribe_track_no_overlap_keeps_legacy_slicing(self):
        sr = tm.SAMPLE_RATE
        wav_path = self.write_wav(duration_sec=31.0, amplitude=1000)
        model = FakeModel()
        islands = [
            {"start": 1 * sr, "end": 21 * sr},
            {"start": 22 * sr, "end": 30 * sr},
        ]

        with patch.object(tm, "detect_speech_islands", return_value=islands):
            segments = tm.transcribe_track(
                wav_path, "Você", model, chunk_by_silence=True, chunk_overlap=False,
            )

        self.assertEqual(len(model.calls[1][0]), (30 - 22) * sr)
        self.assertEqual([round(seg.start, 2) for seg in segments], [1.05, 22.05])

    def test_build_initial_prompt_stays_short_and_excludes_context_terms(self):
        config = tm.TranscriptionConfig(
            language="pt",
            context_terms=["Markdown", "Meeting Transcriber"],
        )

        prompt = tm.build_initial_prompt(config)

        self.assertIn("Reunião de trabalho", prompt)
        self.assertNotIn("Markdown", prompt)
        self.assertNotIn("Meeting Transcriber", prompt)
        self.assertLess(len(prompt), 80)

    def test_build_hotwords_puts_user_terms_after_generic_terms(self):
        config = tm.TranscriptionConfig(
            language="pt",
            context_terms=["Markdown", "Meeting Transcriber"],
            hotwords=["Jira"],
        )

        hotwords = tm.build_hotwords(config)

        # O fim do prompt pesa mais e sobrevive ao corte: termos do usuário
        # vêm depois dos genéricos, sem duplicar "Markdown".
        self.assertTrue(hotwords.endswith("Termos: Markdown, Meeting Transcriber, Jira."))
        self.assertEqual(hotwords.count("Markdown"), 1)
        self.assertIn("backend", hotwords)
        self.assertNotIn("Kubernetes", hotwords)
        self.assertNotIn("Cloud", hotwords)

    def test_build_hotwords_orders_participants_last_and_title_before_them(self):
        config = tm.TranscriptionConfig(
            language="pt",
            glossary=["Atlas Hub"],
            participants=["Ana Maria Souza Lima", "Bruno"],
            title_hint="Cliente X - Checkpoint — 2026-09-23 10:00",
        )

        hotwords = tm.build_hotwords(config)

        self.assertTrue(hotwords.endswith("Participantes: Ana Maria Souza, Bruno."))
        self.assertIn("Reunião: Cliente X - Checkpoint. Participantes:", hotwords)
        self.assertIn("Termos: Atlas Hub. Reunião:", hotwords)
        self.assertNotIn("2026-09-23", hotwords)

    def test_build_hotwords_ignores_default_titles(self):
        for title in ("Reunião 2026-09-23 08:29", "Reunião", "Reunião 2026-09-23 08:29"):
            config = tm.TranscriptionConfig(language="pt", title_hint=title)
            self.assertNotIn("Reunião:", tm.build_hotwords(config) or "")

    def test_build_hotwords_respects_token_budgets_per_part(self):
        config = tm.TranscriptionConfig(
            language="pt",
            glossary=[f"Termo{index}" for index in range(200)],
            participants=[f"Pessoa{index} Sobrenome" for index in range(40)],
            title_hint="Título " * 40,
        )

        hotwords = tm.build_hotwords(config)

        self.assertLessEqual(tm.count_prompt_tokens(hotwords), tm.HOTWORDS_TOKEN_BUDGET)
        # Convidados demais não expulsam o glossário.
        self.assertIn("Termos: Termo0", hotwords)
        self.assertIn("Participantes: Pessoa0 Sobrenome", hotwords)

    def test_transcription_kwargs_keep_full_prompt_within_whisper_limit(self):
        config = tm.TranscriptionConfig(
            language="pt",
            glossary=[f"Termo{index}" for index in range(200)],
            participants=[f"Pessoa{index}" for index in range(40)],
            title_hint="Checkpoint semanal do produto",
        )
        long_tail = " ".join(f"palavra{index}" for index in range(400))

        kwargs = tm.transcription_kwargs(config, vad_filter=False, prompt_tail=long_tail)
        folded = f"{kwargs['initial_prompt']} {kwargs['hotwords']}"

        self.assertLessEqual(tm.count_prompt_tokens(folded), tm.PROMPT_TOKEN_BUDGET)
        # A cauda perde o começo, nunca o fim (contexto mais recente).
        self.assertIn("palavra399", kwargs["initial_prompt"])
        self.assertNotIn("palavra0 ", kwargs["initial_prompt"])

    def test_default_replacements_correct_common_work_terms(self):
        config = tm.load_transcription_config(
            language="pt",
            config_json=None,
            context_terms=[],
            replacement_pairs=[],
        )
        raw_segments = [
            SimpleNamespace(
                start=0.0,
                end=1.0,
                text=" ambiente em OAT com SandPoint, subscriptionion e subscript ion ",
            ),
        ]

        segments = tm.collect_segments(raw_segments, "Interlocutor", 0.0, config)

        self.assertEqual(
            segments[0].text,
            "ambiente em UAT com endpoint, subscription e subscription",
        )
        self.assertEqual(
            segments[0].raw_text,
            "ambiente em OAT com SandPoint, subscriptionion e subscript ion",
        )

    def test_default_replacements_do_not_change_semantic_statement(self):
        config = tm.load_transcription_config(
            language="pt",
            config_json=None,
            context_terms=[],
            replacement_pairs=[],
        )
        raw_segments = [
            SimpleNamespace(
                start=0.0,
                end=1.0,
                text=" Isso vai obrigar muito time a mudar de processo. ",
            ),
        ]

        segments = tm.collect_segments(raw_segments, "Você", 0.0, config)

        self.assertEqual(segments[0].text, "Isso vai obrigar muito time a mudar de processo.")
        self.assertEqual(segments[0].raw_text, segments[0].text)

    def test_default_replacements_can_be_disabled(self):
        config = tm.load_transcription_config(
            language="pt",
            config_json=None,
            context_terms=[],
            replacement_pairs=[],
            use_default_replacements=False,
        )

        self.assertNotIn("OAT", config.replacements)

    def test_collect_segments_applies_explicit_replacements(self):
        config = tm.TranscriptionConfig(
            replacements={"Crisp": "Krisp", "maquedal": "Markdown"},
        )
        raw_segments = [
            SimpleNamespace(start=0.0, end=1.0, text=" Crisp e maquedal "),
        ]

        segments = tm.collect_segments(raw_segments, "Você", 0.0, config)

        self.assertEqual(segments[0].text, "Krisp e Markdown")
        self.assertEqual(segments[0].raw_text, "Crisp e maquedal")

    def test_collect_segments_collapses_runaway_repeated_sentences(self):
        config = tm.TranscriptionConfig()
        raw_segments = [
            SimpleNamespace(
                start=0.0,
                end=1.0,
                text=(
                    " Como que eu faço isso? Como que eu faço isso? "
                    "Como que eu faço isso? Como que eu faço isso? Como que eu "
                ),
            ),
        ]

        segments = tm.collect_segments(raw_segments, "Interlocutor", 0.0, config)

        self.assertEqual(
            segments[0].text,
            "Como que eu faço isso? Como que eu faço isso?",
        )

    def test_collect_segments_collapses_intrasentence_repeated_ngrams(self):
        config = tm.TranscriptionConfig()
        raw_segments = [
            SimpleNamespace(
                start=0.0,
                end=1.0,
                text=" Ferreira Ferreira Ferreira Ferreira Ferreira Ferreira agora segue.",
            ),
            SimpleNamespace(
                start=2.0,
                end=3.0,
                text=" thumbs down thumbs down thumbs down thumbs down thumbs down ok.",
            ),
        ]

        segments = tm.collect_segments(raw_segments, "Interlocutor", 0.0, config)

        self.assertEqual(segments[0].text, "Ferreira agora segue.")
        self.assertEqual(segments[1].text, "thumbs down ok.")

    def test_collect_segments_sanitizes_intraword_runaways_before_laughter(self):
        config = tm.TranscriptionConfig()
        raw_segments = [
            SimpleNamespace(
                start=0.0,
                end=1.0,
                text=" FooterKidsKidsKidsKidsKids agora segue ",
                avg_logprob=-0.2,
                no_speech_prob=0.1,
            ),
            SimpleNamespace(
                start=2.0,
                end=3.0,
                text=" KKKK Obrigada ",
                avg_logprob=-0.2,
                no_speech_prob=0.1,
            ),
            SimpleNamespace(
                start=4.0,
                end=5.0,
                text=" KKKKKKKKKKKK ",
                avg_logprob=-0.2,
                no_speech_prob=0.1,
            ),
            SimpleNamespace(
                start=6.0,
                end=7.0,
                text=" em 50KKKK ",
                avg_logprob=-0.2,
                no_speech_prob=0.1,
            ),
        ]

        segments = tm.collect_segments(raw_segments, "Interlocutor", 0.0, config)

        self.assertEqual(segments[0].text, "[inaudível] agora segue")
        self.assertTrue(segments[0].text_is_suspect)
        self.assertEqual(segments[1].text, "[risos] Obrigada")
        self.assertFalse(segments[1].text_is_suspect)
        self.assertEqual(segments[2].text, "[inaudível]")
        self.assertTrue(segments[2].text_is_suspect)
        self.assertEqual(segments[3].text, "em [inaudível]")
        self.assertTrue(segments[3].text_is_suspect)

    def test_collect_segments_sanitizes_unicode_runaway_repetitions(self):
        config = tm.TranscriptionConfig()
        raw_segments = [
            SimpleNamespace(
                start=0.0,
                end=1.0,
                text=" っぱ" * 40,
                avg_logprob=-0.2,
                no_speech_prob=0.1,
            ),
        ]

        segments = tm.collect_segments(raw_segments, "Você", 0.0, config)

        self.assertEqual(segments[0].text, "[inaudível]")
        self.assertTrue(segments[0].text_is_suspect)

    def test_segment_is_suspect_uses_raw_text_density_before_sanitization(self):
        segment = tm.Segment(
            start=0.0,
            end=1.0,
            text="[inaudível]",
            speaker="Interlocutor",
            avg_logprob=-0.2,
            no_speech_prob=0.1,
            raw_text="FooterKids" * 60,
        )

        self.assertTrue(tm.segment_is_suspect(segment))

    def test_chunk_by_silence_skips_low_energy_chunks(self):
        wav_path = self.write_wav(amplitude=0)
        model = FakeModel()

        with patch.object(
            tm,
            "detect_speech_islands",
            return_value=[{"start": 0, "end": tm.SAMPLE_RATE}],
        ):
            segments = tm.transcribe_track(
                wav_path,
                "Você",
                model,
                chunk_by_silence=True,
            )

        self.assertEqual(segments, [])
        self.assertEqual(model.calls, [])

    def test_transcribe_track_carries_clean_context_between_chunks(self):
        sr = tm.SAMPLE_RATE
        wav_path = self.write_wav(duration_sec=7.0, amplitude=1000)

        class ContextFakeModel:
            def __init__(self):
                self.calls = []

            def transcribe(self, audio_input, **kwargs):
                self.calls.append(kwargs)
                text = " primeira parte " if len(self.calls) == 1 else " segunda parte "
                return [
                    SimpleNamespace(
                        start=0.05,
                        end=0.50,
                        text=text,
                        avg_logprob=-0.2,
                        no_speech_prob=0.1,
                    )
                ], SimpleNamespace(duration=len(audio_input) / sr, language="pt", language_probability=0.99)

        islands = [
            {"start": 0, "end": 1 * sr},
            {"start": 5 * sr, "end": 6 * sr},
        ]
        model = ContextFakeModel()

        with patch.object(tm, "detect_speech_islands", return_value=islands):
            tm.transcribe_track(wav_path, "Você", model, chunk_by_silence=True)

        self.assertNotIn("Contexto anterior", model.calls[0]["initial_prompt"])
        self.assertIn("Contexto anterior recente: primeira parte", model.calls[1]["initial_prompt"])

    def test_mlx_backend_uses_cached_snapshot_and_drops_unsupported_beam_size(self):
        captured = {}

        def fake_snapshot_download(repo, local_files_only):
            self.assertEqual(repo, "mlx-community/test")
            self.assertTrue(local_files_only)
            return "/cached/mlx-model"

        def fake_transcribe(audio_input, **kwargs):
            captured.update(kwargs)
            return {
                "segments": [{
                    "start": 0.0,
                    "end": 1.0,
                    "text": " ok ",
                    "avg_logprob": -0.2,
                    "no_speech_prob": 0.1,
                }],
                "language": "pt",
            }

        fake_hub = SimpleNamespace(snapshot_download=fake_snapshot_download)
        fake_mlx = SimpleNamespace(transcribe=fake_transcribe)

        with patch.dict(sys.modules, {"huggingface_hub": fake_hub, "mlx_whisper": fake_mlx}):
            segments, info = tm.MlxBackend("mlx-community/test").transcribe(
                np.zeros(tm.SAMPLE_RATE, dtype=np.float32),
                language="pt",
                initial_prompt="prompt",
                hotwords="term",
                beam_size=5,
                word_timestamps=True,
            )

        self.assertEqual(captured["path_or_hf_repo"], "/cached/mlx-model")
        self.assertEqual(captured["initial_prompt"], "prompt term")
        self.assertIsNone(captured["verbose"])
        self.assertTrue(captured["word_timestamps"])
        self.assertNotIn("beam_size", captured)
        self.assertEqual(segments[0].text, " ok ")
        self.assertEqual(segments[0].avg_logprob, -0.2)
        self.assertEqual(segments[0].no_speech_prob, 0.1)
        self.assertEqual(info.language, "pt")

    def test_mlx_backend_falls_back_to_repo_id_when_snapshot_is_not_cached(self):
        captured = {}

        def fake_snapshot_download(repo, local_files_only):
            raise RuntimeError("not cached")

        def fake_transcribe(audio_input, **kwargs):
            captured.update(kwargs)
            return {"segments": [], "language": "pt"}

        fake_hub = SimpleNamespace(snapshot_download=fake_snapshot_download)
        fake_mlx = SimpleNamespace(transcribe=fake_transcribe)

        with patch.dict(sys.modules, {"huggingface_hub": fake_hub, "mlx_whisper": fake_mlx}):
            tm.MlxBackend("mlx-community/test").transcribe(
                np.zeros(tm.SAMPLE_RATE, dtype=np.float32),
                language="pt",
            )

        self.assertEqual(captured["path_or_hf_repo"], "mlx-community/test")

    def test_load_transcription_config_merges_json_and_cli_values(self):
        payload = {
            "context_terms": ["Markdown"],
            "replacements": {"Crisp": "Krisp"},
        }
        tmp = tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False)
        json.dump(payload, tmp)
        tmp.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))

        config = tm.load_transcription_config(
            language="pt",
            config_json=tmp.name,
            context_terms=["Meeting Transcriber"],
            replacement_pairs=[("maquedal", "Markdown")],
        )

        self.assertEqual(config.context_terms, ["Markdown", "Meeting Transcriber"])
        self.assertEqual(config.replacements["Crisp"], "Krisp")
        self.assertEqual(config.replacements["maquedal"], "Markdown")

    def test_validate_audio_inputs_rejects_missing_file(self):
        parser = FakeParser()
        args = SimpleNamespace(mic="/tmp/missing-mic.wav", system=None)

        with self.assertRaises(SystemExit) as raised:
            tm.validate_audio_inputs(parser, args)

        self.assertEqual(raised.exception.code, 2)
        self.assertIn("Arquivo de áudio do microfone não encontrado", parser.message)

    def test_validate_audio_inputs_rejects_corrupt_header(self):
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.write(b"RIFF" + b"\x00" * 100)   # > 44 bytes, mas header inválido
        tmp.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))

        parser = FakeParser()
        args = SimpleNamespace(mic=tmp.name, system=None)

        with self.assertRaises(SystemExit):
            tm.validate_audio_inputs(parser, args)

        self.assertIn("corrompido ou truncado", parser.message)

    def test_validate_audio_inputs_rejects_truncated_data(self):
        wav_path = self.write_wav(duration_sec=3.0, amplitude=1000)
        full_size = Path(wav_path).stat().st_size
        with open(wav_path, "r+b") as handle:
            handle.truncate(full_size // 2)

        parser = FakeParser()
        args = SimpleNamespace(mic=None, system=wav_path)

        with self.assertRaises(SystemExit):
            tm.validate_audio_inputs(parser, args)

        self.assertIn("corrompido ou truncado", parser.message)

    def test_validate_audio_inputs_rejects_empty_audio(self):
        samples = np.zeros(0, dtype=np.int16)
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        wavfile.write(tmp.name, tm.SAMPLE_RATE, samples)
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))

        parser = FakeParser()
        args = SimpleNamespace(mic=tmp.name, system=None)

        with self.assertRaises(SystemExit):
            tm.validate_audio_inputs(parser, args)

        self.assertIn("vazio", parser.message)

    def test_validate_audio_inputs_rejects_wrong_sample_rate(self):
        samples = np.zeros(8000, dtype=np.int16)
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        wavfile.write(tmp.name, 8000, samples)
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))

        parser = FakeParser()
        args = SimpleNamespace(mic=tmp.name, system=None)

        with self.assertRaises(SystemExit):
            tm.validate_audio_inputs(parser, args)

        self.assertIn("16000Hz", parser.message)

    def test_consolidate_turns_keeps_same_speaker_separate_across_interjection(self):
        segments = [
            tm.Segment(0.0, 1.0, "primeira parte", "Você", avg_logprob=-0.2),
            tm.Segment(1.1, 1.2, "aham", "Interlocutor", avg_logprob=-0.3),
            tm.Segment(1.4, 2.0, "segunda parte", "Você", avg_logprob=-0.4),
        ]

        turns = tm.consolidate_turns(segments)

        self.assertEqual(len(turns), 3)
        self.assertEqual(turns[0].speaker, "Você")
        self.assertEqual(turns[0].text, "primeira parte")
        self.assertEqual(turns[0].start_ms, 0)
        self.assertEqual(turns[0].end_ms, 1000)
        self.assertEqual(turns[1].speaker, "Interlocutor")
        self.assertEqual(turns[1].text, "aham")
        self.assertEqual(turns[2].speaker, "Você")
        self.assertEqual(turns[2].text, "segunda parte")

    def test_consolidate_turns_avoids_artificial_overlap_for_a_b_a(self):
        segments = [
            tm.Segment(0.0, 1.0, "primeira parte", "Você"),
            tm.Segment(1.1, 1.2, "aham", "Interlocutor"),
            tm.Segment(1.4, 2.0, "segunda parte", "Você"),
        ]

        turns = tm.consolidate_turns(segments)
        rows = [json.loads(line) for line in tm.build_analysis_jsonl(turns).splitlines()]

        self.assertEqual([row["overlap_ms"] for row in rows], [0, 0, 0])

    def test_build_jsonl_outputs_parseable_turn_objects(self):
        turns = [
            tm.Turn(
                speaker="Você",
                text="texto",
                start_ms=1000,
                end_ms=2000,
                confidence=0.94,
                is_suspect=False,
            )
        ]

        payload = [json.loads(line) for line in tm.build_jsonl(turns).splitlines()]

        self.assertEqual(payload, [{
            "speaker": "Você",
            "text": "texto",
            "start_ms": 1000,
            "end_ms": 2000,
            "confidence": 0.94,
            "is_suspect": False,
        }])

    def test_relabel_system_speakers_keeps_one_label_without_repeated_evidence(self):
        system_audio = np.concatenate([
            np.full(tm.SAMPLE_RATE, 1000 / 32768.0, dtype=np.float32),
            np.zeros(tm.SAMPLE_RATE, dtype=np.float32),
            np.full(tm.SAMPLE_RATE, 8000 / 32768.0, dtype=np.float32),
        ])
        segments = [
            tm.Segment(0.0, 1.0, "baixo", "Interlocutor"),
            tm.Segment(2.0, 3.0, "alto", "Interlocutor"),
        ]

        with patch.dict(sys.modules, {"resemblyzer": None}):
            tm.relabel_system_speakers(segments, system_audio, 0.0)

        self.assertEqual(segments[0].speaker, "Remote_A")
        self.assertEqual(segments[1].speaker, "Remote_A")

    def test_normalize_known_names_corrects_similar_token(self):
        # "Ferreirá" (accent typo, ~88% similar) and "Fereira" (~93%) should be replaced
        for variant in ("Ferreirá", "Fereira", "Ferrera"):
            with self.subTest(variant=variant):
                result = tm.normalize_known_names(f"Então o {variant} falou isso", ["Ferreira"])
                self.assertIn("Ferreira", result, f"Expected {variant!r} → Ferreira")

    def test_normalize_known_names_leaves_dissimilar_tokens_alone(self):
        result = tm.normalize_known_names("Isso é muito bom", ["Ferreira"])
        self.assertEqual(result, "Isso é muito bom")

    def test_normalize_known_names_ignores_short_tokens(self):
        # Short tokens (< 4 chars) should not be touched even if similar
        result = tm.normalize_known_names("por", ["Ferreira"])
        self.assertEqual(result, "por")

    def test_consolidate_turns_respects_max_turn_duration(self):
        # Three consecutive segments of the same speaker spanning > 60s
        segments = [
            tm.Segment(0.0, 25.0, "parte A", "Interlocutor"),
            tm.Segment(26.0, 50.0, "parte B", "Interlocutor"),
            tm.Segment(51.0, 75.0, "parte C", "Interlocutor"),
        ]
        # With 60s max, the 3rd segment would push span to 75s — must start new turn
        turns = tm.consolidate_turns(segments, gap_threshold_s=2.0, max_turn_duration_s=60.0)
        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0].text, "parte A parte B")
        self.assertEqual(turns[1].text, "parte C")

    def test_consolidate_turns_splits_single_long_segment(self):
        segments = [
            tm.Segment(
                0.0,
                57.0,
                " ".join(f"palavra{i}" for i in range(18)),
                "Interlocutor",
            ),
        ]

        turns = tm.consolidate_turns(segments, max_turn_duration_s=30.0)

        self.assertEqual(len(turns), 2)
        self.assertLessEqual((turns[0].end_ms - turns[0].start_ms) / 1000.0, 30.0)
        self.assertLessEqual((turns[1].end_ms - turns[1].start_ms) / 1000.0, 30.0)
        self.assertIn("palavra0", turns[0].text)
        self.assertIn("palavra17", turns[1].text)

    def test_consolidate_turns_splits_sparse_long_segment_with_placeholder(self):
        segments = [
            tm.Segment(0.0, 57.0, "ok", "Interlocutor"),
        ]

        turns = tm.consolidate_turns(segments, max_turn_duration_s=30.0)

        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0].text, "ok")
        self.assertEqual(turns[1].text, "[inaudível]")
        self.assertTrue(turns[1].is_suspect)
        self.assertLessEqual((turns[1].end_ms - turns[1].start_ms) / 1000.0, 30.0)

    def test_low_confidence_text_is_flagged_not_erased(self):
        turn = tm.turn_from_segments([
            tm.Segment(
                0.0,
                1.0,
                "Bom dia",
                "Você",
                avg_logprob=-1.2,
                no_speech_prob=0.1,
            )
        ])

        row = json.loads(tm.build_jsonl([turn]).strip())

        self.assertTrue(row["is_suspect"])
        self.assertEqual(row["text"], "Bom dia")

    def test_build_jsonl_sanitizes_suspect_turns_by_default(self):
        turns = [
            tm.Turn(
                "Interlocutor",
                "texto limpo [inaudível]",
                0,
                1000,
                0.8,
                True,
                raw_text="texto limpo FooterKidsKidsKidsKidsKids",
                safe_text="texto limpo [inaudível]",
            ),
        ]

        row = json.loads(tm.build_jsonl(turns).strip())

        self.assertEqual(row["text"], "texto limpo [inaudível]")
        self.assertTrue(row["is_suspect"])

    def test_build_markdown_uses_sanitized_text_for_structural_artifacts(self):
        turns = [
            tm.Turn(
                "Você",
                "っぱ" * 80,
                0,
                1000,
                0.01,
                True,
                raw_text="っぱ" * 80,
                safe_text="[inaudível]",
            ),
        ]

        markdown = tm.build_markdown("Teste", turns, dual_track=True, language="pt")

        self.assertIn("[inaudível] ⚠ suspeito", markdown)
        self.assertNotIn("っぱっぱ", markdown)

    def test_build_jsonl_can_emit_raw_text_for_debug(self):
        turns = [
            tm.Turn(
                "Interlocutor",
                "[inaudível]",
                0,
                1000,
                0.8,
                True,
                raw_text="FooterKidsKidsKidsKidsKids",
                safe_text="[inaudível]",
            ),
        ]

        row = json.loads(tm.build_jsonl(turns, sanitize_suspect=False).strip())

        self.assertEqual(row["text"], "FooterKidsKidsKidsKidsKids")

    def test_build_jsonl_preserves_raw_asr_when_replacements_changed_text(self):
        turns = [
            tm.Turn(
                "Você", "ambiente em UAT", 0, 1000, 0.9, False,
                raw_text="ambiente em OAT",
            ),
        ]

        row = json.loads(tm.build_jsonl(turns).strip())

        self.assertEqual(row["text"], "ambiente em UAT")
        self.assertEqual(row["raw_text"], "ambiente em OAT")

    def test_build_jsonl_preserves_source_when_safe_text_changes_output(self):
        turn = tm.Turn(
            "Você", "texto bruto", 0, 1000, 0.1, True,
            raw_text=None,
            safe_text="[inaudível]",
        )

        row = json.loads(tm.build_jsonl([turn]).strip())

        self.assertEqual(row["text"], "[inaudível]")
        self.assertEqual(row["raw_text"], "texto bruto")

    def test_write_text_atomic_leaves_complete_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "transcript.jsonl"

            tm.write_text_atomic(destination, '{"type":"turn"}\n')

            self.assertEqual(destination.read_text(encoding="utf-8"), '{"type":"turn"}\n')
            self.assertEqual(list(Path(tmp).glob("*.inprogress")), [])

    def test_build_jsonl_filter_suspect_removes_flagged_turns(self):
        turns = [
            tm.Turn("Você", "texto limpo", 0, 1000, 0.9, False),
            tm.Turn("Interlocutor", "texto suspeito", 1000, 2000, 0.3, True),
        ]
        output = tm.build_jsonl(turns, filter_suspect=True)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["speaker"], "Você")

    def test_build_jsonl_filter_suspect_false_keeps_all(self):
        turns = [
            tm.Turn("Você", "limpo", 0, 1000, 0.9, False),
            tm.Turn("Interlocutor", "suspeito", 1000, 2000, 0.3, True),
        ]
        output = tm.build_jsonl(turns, filter_suspect=False)
        self.assertEqual(len(output.splitlines()), 2)

    def test_collect_segments_normalizes_verse_formatting(self):
        config = tm.TranscriptionConfig()
        raw = [
            SimpleNamespace(
                start=0.0, end=1.0,
                text="linha um\nlinha dois\nlinha três",
                avg_logprob=-0.3, no_speech_prob=0.1,
            )
        ]
        segs = tm.collect_segments(raw, "Você", 0.0, config)
        self.assertEqual(segs[0].text, "linha um linha dois linha três")


class LlmOutputTests(unittest.TestCase):
    def make_turns(self):
        return [
            tm.Turn("Você", "fala local", 0, 1000, 0.9, False),
            tm.Turn("Remote_A", "fala remota", 1500, 3000, 0.8, False),
        ]

    def make_meta(self, turns):
        return tm.build_meeting_meta(
            title="Planejamento",
            language="pt",
            turns=turns,
            tracks="both",
            backend="mlx",
            model_name="mlx-community/whisper-large-v3-mlx",
        )

    def test_build_jsonl_with_meta_emits_meta_first_and_typed_turns(self):
        turns = self.make_turns()
        meta = self.make_meta(turns)

        rows = [json.loads(line) for line in tm.build_jsonl(turns, meta=meta).splitlines()]

        self.assertEqual(rows[0]["type"], "meta")
        self.assertEqual(rows[0]["title"], "Planejamento")
        self.assertEqual(rows[0]["duration_ms"], 3000)
        self.assertEqual(rows[0]["speakers"], ["Remote_A", "Você"])
        self.assertEqual(rows[0]["tracks"], "both")
        self.assertEqual(rows[0]["backend"], "mlx")
        self.assertEqual(rows[0]["pipeline_version"], tm.PIPELINE_VERSION)
        self.assertTrue(all(row["type"] == "turn" for row in rows[1:]))
        self.assertEqual(rows[1]["speaker"], "Você")

    def test_capture_integrity_and_session_provenance_are_exported(self):
        turns = self.make_turns()
        meta = tm.build_meeting_meta(
            title="Planejamento",
            language="pt",
            turns=turns,
            tracks="both",
            backend="mlx",
            model_name="modelo",
            session_id="session-123",
            capture_integrity="degraded",
            capture_issues=["microfone terminou cedo"],
            recorded_at="2026-09-10T09:00:00-03:00",
        )

        self.assertEqual(meta["session_id"], "session-123")
        self.assertEqual(meta["date"], "2026-09-10T09:00:00-03:00")
        self.assertEqual(meta["capture_integrity"], "degraded")
        self.assertEqual(meta["capture_issues"], ["microfone terminou cedo"])
        self.assertIn("processed_at", meta)

        markdown = tm.build_markdown(
            "Planejamento",
            turns,
            dual_track=True,
            language="pt",
            capture_integrity="degraded",
            capture_issues=["microfone terminou cedo"],
            recorded_at="2026-09-10T09:00:00-03:00",
        )
        self.assertIn("Captura parcial", markdown)
        self.assertIn("microfone terminou cedo", markdown)

    def test_build_jsonl_without_meta_has_no_type_field(self):
        turns = self.make_turns()

        rows = [json.loads(line) for line in tm.build_jsonl(turns, meta=None).splitlines()]

        self.assertTrue(all("type" not in row for row in rows))

    def test_parse_speaker_map_parses_pairs(self):
        mapping = tm.parse_speaker_map("Remote_A=Alex, Remote_B=Jordan")
        self.assertEqual(mapping, {"Remote_A": "Alex", "Remote_B": "Jordan"})

    def test_parse_speaker_map_rejects_malformed_input(self):
        import argparse
        for bad in ("Remote_A", "=Alex", "Remote_A="):
            with self.subTest(bad=bad):
                with self.assertRaises(argparse.ArgumentTypeError):
                    tm.parse_speaker_map(bad)

    def test_parse_metadata_pair_parses_key_value(self):
        self.assertEqual(tm.parse_metadata_pair("org=ExampleCo"), ("org", "ExampleCo"))

    def test_parse_metadata_pair_rejects_malformed_input(self):
        import argparse
        for bad in ("org", "=ExampleCo", "org="):
            with self.subTest(bad=bad):
                with self.assertRaises(argparse.ArgumentTypeError):
                    tm.parse_metadata_pair(bad)

    def test_apply_speaker_map_renames_only_mapped_labels(self):
        turns = self.make_turns()

        tm.apply_speaker_map(turns, {"Remote_A": "Alex"})

        self.assertEqual(turns[0].speaker, "Você")
        self.assertEqual(turns[1].speaker, "Alex")

    def test_speaker_map_propagates_to_meta_speakers(self):
        turns = self.make_turns()
        tm.apply_speaker_map(turns, {"Remote_A": "Alex"})

        meta = self.make_meta(turns)

        self.assertEqual(meta["speakers"], ["Alex", "Você"])

    def test_build_llm_package_is_self_contained(self):
        turns = self.make_turns()
        meta = self.make_meta(turns)
        jsonl_text = tm.build_jsonl(turns, meta=meta)

        package = tm.build_llm_package(meta, jsonl_text)

        self.assertIn("# Transcrição de reunião: Planejamento", package)
        self.assertIn("Remote_A, Você", package)
        self.assertIn("```jsonl", package)
        self.assertIn('"type":"meta"', package)
        self.assertIn('"type":"turn"', package)
        self.assertIn("[inaudível]", package)   # instrução de contexto explica os marcadores
        # O bloco JSONL embutido precisa continuar parseável linha a linha
        fenced = package.split("```jsonl\n", 1)[1].split("\n```", 1)[0]
        for line in fenced.splitlines():
            json.loads(line)

    def test_build_analysis_jsonl_appends_chunk_diagnostics_for_review(self):
        turns = [tm.Turn(speaker="Interlocutor", text="oi", start_ms=0, end_ms=900, confidence=0.9, is_suspect=False, track="system")]
        chunks = {"system": [{"index": 1, "start_ms": 0, "end_ms": 1000, "slice_start_ms": 0, "hotwords": True}]}

        rows = [
            json.loads(line)
            for line in tm.build_analysis_jsonl(turns, meta={"title": "t"}, chunks=chunks, purpose="review").splitlines()
        ]

        self.assertEqual([row["type"] for row in rows], ["meta", "turn", "chunk"])
        self.assertEqual(rows[0]["purpose"], "review")
        self.assertEqual(rows[2]["track"], "system")
        self.assertTrue(rows[2]["hotwords"])

    def test_meeting_meta_records_track_offsets(self):
        meta = tm.build_meeting_meta(
            title="t", language="pt", turns=[], tracks="both", backend="mlx", model_name="m",
            track_offsets_ms={"mic": 0.0, "system": 202.0},
        )

        self.assertEqual(meta["track_offsets_ms"], {"mic": 0.0, "system": 202.0})

    def test_build_analysis_jsonl_preserves_social_and_quality_signals(self):
        turns = [
            tm.Turn(
                "Você",
                "texto limpo",
                0,
                2000,
                0.9,
                False,
                track="mic",
            ),
            tm.Turn(
                "Interlocutor",
                "[inaudível]",
                1500,
                3000,
                0.4,
                True,
                raw_text="texto bruto alucinado",
                safe_text="[inaudível]",
                track="system",
            ),
        ]
        meta = tm.build_meeting_meta(
            title="Planejamento",
            language="pt",
            turns=turns,
            tracks="both",
            backend="mlx",
            model_name="mlx-community/whisper-large-v3-mlx",
            analysis_context={"org": "ExampleCo", "role": "facilitator"},
            participants=["Alex", "Jordan"],
            analysis_goal="Identificar persona",
        )

        rows = [json.loads(line) for line in tm.build_analysis_jsonl(turns, meta=meta).splitlines()]

        self.assertEqual(rows[0]["type"], "meta")
        self.assertEqual(rows[0]["purpose"], "persona_analysis")
        self.assertEqual(rows[0]["context"], {"org": "ExampleCo", "role": "facilitator"})
        self.assertEqual(rows[0]["participants_expected"], ["Alex", "Jordan"])
        self.assertEqual(rows[1]["track"], "mic")
        self.assertEqual(rows[1]["duration_ms"], 2000)
        self.assertEqual(rows[1]["overlap_ms"], 0)
        self.assertEqual(rows[2]["track"], "system")
        self.assertEqual(rows[2]["raw_text"], "texto bruto alucinado")
        self.assertEqual(rows[2]["safe_text"], "[inaudível]")
        self.assertEqual(rows[2]["overlap_ms"], 500)
        self.assertIn("low_confidence", rows[2]["quality_flags"])
        self.assertIn("remote_unclustered", rows[2]["quality_flags"])


class DiarizationTests(unittest.TestCase):
    def make_two_speaker_audio_and_segments(self):
        sr = tm.SAMPLE_RATE
        rng = np.random.default_rng(42)
        t = np.arange(sr) / sr
        loud_smooth = (0.5 * np.sin(2 * np.pi * 120 * t)).astype(np.float32)
        quiet_noisy = (0.02 * rng.standard_normal(sr)).astype(np.float32)
        audio = np.concatenate([loud_smooth, quiet_noisy, loud_smooth, quiet_noisy])
        segments = [
            tm.Segment(0.0, 1.0, "fala um", "Interlocutor"),
            tm.Segment(1.0, 2.0, "fala dois", "Interlocutor"),
            tm.Segment(2.0, 3.0, "fala três", "Interlocutor"),
            tm.Segment(3.0, 4.0, "fala quatro", "Interlocutor"),
        ]
        return audio, segments

    def test_relabel_heuristic_separates_two_distinct_speakers(self):
        audio, segments = self.make_two_speaker_audio_and_segments()

        tm._relabel_heuristic(segments, audio, 0.0)

        self.assertEqual(
            [seg.speaker for seg in segments],
            ["Remote_A", "Remote_B", "Remote_A", "Remote_B"],
        )

    def test_relabel_heuristic_labels_are_deterministic(self):
        audio, first = self.make_two_speaker_audio_and_segments()
        _, second = self.make_two_speaker_audio_and_segments()

        tm._relabel_heuristic(first, audio, 0.0)
        tm._relabel_heuristic(second, audio, 0.0)

        self.assertEqual(
            [seg.speaker for seg in first],
            [seg.speaker for seg in second],
        )

    def test_relabel_system_speakers_falls_back_when_resemblyzer_missing(self):
        audio, segments = self.make_two_speaker_audio_and_segments()

        # None em sys.modules faz "from resemblyzer import ..." levantar ImportError
        with patch.dict(sys.modules, {"resemblyzer": None}):
            tm.relabel_system_speakers(segments, audio, 0.0)

        self.assertEqual(
            [seg.speaker for seg in segments],
            ["Remote_A", "Remote_B", "Remote_A", "Remote_B"],
        )

    def test_relabel_resemblyzer_clusters_with_fake_encoder(self):
        audio, segments = self.make_two_speaker_audio_and_segments()

        class FakeEncoder:
            embedding_size = 4

            def __init__(self, device):
                pass

            def embed_utterance(self, wav):
                level = float(np.mean(np.abs(wav)))
                if level > 0.1:
                    return np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float32)
                return np.array([0.0, 1.0, 0.0, 0.0], dtype=np.float32)

        fake_module = SimpleNamespace(
            VoiceEncoder=FakeEncoder,
            preprocess_wav=lambda wav, source_sr: wav,
        )

        with patch.dict(sys.modules, {"resemblyzer": fake_module}):
            tm._relabel_resemblyzer(segments, audio, 0.0, max_speakers=8)

        self.assertEqual(
            [seg.speaker for seg in segments],
            ["Remote_A", "Remote_B", "Remote_A", "Remote_B"],
        )

    def test_relabel_resemblyzer_keeps_one_label_without_cluster_evidence(self):
        audio, segments = self.make_two_speaker_audio_and_segments()

        class FakeEncoder:
            embedding_size = 4

            def __init__(self, device):
                pass

            def embed_utterance(self, wav):
                return np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float32)

        fake_module = SimpleNamespace(
            VoiceEncoder=FakeEncoder,
            preprocess_wav=lambda wav, source_sr: wav,
        )

        with patch.dict(sys.modules, {"resemblyzer": fake_module}):
            tm._relabel_resemblyzer(segments, audio, 0.0, max_speakers=8)

        self.assertEqual([seg.speaker for seg in segments], ["Remote_A"] * 4)

    def test_relabel_resemblyzer_keeps_non_system_segments_untouched(self):
        audio, segments = self.make_two_speaker_audio_and_segments()
        segments.append(tm.Segment(4.0, 5.0, "fala do mic", "Você"))

        with patch.dict(sys.modules, {"resemblyzer": None}):
            tm.relabel_system_speakers(segments, audio, 0.0)

        self.assertEqual(segments[-1].speaker, "Você")


if __name__ == "__main__":
    unittest.main()
