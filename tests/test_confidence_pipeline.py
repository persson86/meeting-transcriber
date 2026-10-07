"""Pipeline 0.10.0: texto sem erros estruturais (F6a–F6g), com fixtures sintéticas.

Nenhum teste carrega modelo, rede ou áudio real: o backend e o VAD são falsos,
e os WAVs são tons constantes gerados aqui.
"""
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import transcribe_meeting as tm  # noqa: E402
import transcript_signals as signals  # noqa: E402

SR = tm.SAMPLE_RATE
INFO = SimpleNamespace(language="pt", language_probability=0.9)


def seg(start, end, text, words=None, **extra):
    fields = dict(start=start, end=end, text=text, avg_logprob=-0.2, no_speech_prob=0.1)
    fields.update(extra)
    if words is not None:
        fields["words"] = words
    return SimpleNamespace(**fields)


def even_words(start, end, text):
    """Tempos por palavra distribuídos por igual (como o decoder entregaria)."""
    tokens = text.split()
    step = (end - start) / len(tokens)
    return [
        {"word": f" {token}", "start": start + index * step, "end": start + (index + 1) * step}
        for index, token in enumerate(tokens)
    ]


class ScriptedModel:
    """Backend falso: devolve respostas na ordem das chamadas e registra os kwargs."""

    def __init__(self, responses, languages=None):
        self.responses = list(responses)
        self.languages = list(languages or [])
        self.calls = []
        self.detect_calls = 0

    def transcribe(self, audio_input, **kwargs):
        self.calls.append(kwargs)
        segments = self.responses.pop(0) if self.responses else []
        return segments, INFO

    def detect_language(self, audio_chunk):
        self.detect_calls += 1
        return self.languages.pop(0) if self.languages else "pt"


class PipelineHarness(unittest.TestCase):
    def write_wav(self, duration_sec, amplitude=1000):
        samples = np.full(int(duration_sec * SR), amplitude, dtype=np.int16)
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        wavfile.write(tmp.name, SR, samples)
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return tmp.name

    def run_main(self, model, islands_by_track, extra_args=(), mic_sec=20.0, system_sec=20.0):
        """Roda main() com backend e VAD falsos; devolve (md, analysis rows, jsonl rows, stdout)."""
        mic = self.write_wav(mic_sec)
        system = self.write_wav(system_sec)
        out_dir = tempfile.mkdtemp()
        islands_queue = [islands_by_track["mic"], islands_by_track["system"]]
        argv = [
            "transcribe_meeting.py", "--mic", mic, "--system", system, "--out", out_dir,
            "--title", "Teste sintético", "--with-analysis",
            "--recorded-at", "2026-10-07T09:00:00-03:00", *extra_args,
        ]
        stdout = io.StringIO()
        with patch.object(sys, "argv", argv), \
                patch.object(tm, "MlxBackend", return_value=model), \
                patch.object(tm, "detect_speech_islands", side_effect=lambda audio: islands_queue.pop(0)), \
                redirect_stdout(stdout):
            tm.main()
        md_path = next(Path(out_dir).glob("*.md"))
        analysis_path = next(Path(out_dir).glob("*.analysis.jsonl"))
        jsonl_path = next(p for p in Path(out_dir).glob("*.jsonl") if not p.name.endswith(".analysis.jsonl"))
        analysis = [json.loads(line) for line in analysis_path.read_text(encoding="utf-8").splitlines()]
        jsonl = [json.loads(line) for line in jsonl_path.read_text(encoding="utf-8").splitlines()]
        return md_path.read_text(encoding="utf-8"), analysis, jsonl, stdout.getvalue()


# ---------------------------------------------------------------------------
# F6a — fala detectada pelo VAD não some em silêncio
# ---------------------------------------------------------------------------

class UntranscribedSpeechTests(PipelineHarness):
    def test_markdown_marks_block_with_vad_speech_and_empty_asr(self):
        model = ScriptedModel([
            [seg(0.1, 1.5, " começo da reunião ")],   # mic, bloco 1
            [],                                          # mic, bloco 2: 6 s de fala, ASR vazio
            [],                                          # mic, bloco 2: retry sem vocabulário, vazio de novo
            [seg(0.1, 1.0, " oi pessoal ")],             # sistema
        ])
        md, analysis, _, _ = self.run_main(model, {
            "mic": [{"start": 0, "end": 2 * SR}, {"start": 8 * SR, "end": 14 * SR}],
            "system": [{"start": 0, "end": 2 * SR}],
        })

        self.assertIn("**Você:** [00:08] [sem texto 6 s]", md)
        chunks = [row for row in analysis if row["type"] == "chunk" and row["track"] == "mic"]
        self.assertEqual(chunks[1]["skipped_reason"], "empty_asr")
        self.assertEqual(chunks[1]["covered_ms"], 0)
        self.assertIn("fala sem texto: 6 s em 1 trecho (00:08)", md)
        self.assertIn("**Interlocutor:** [00:00] oi pessoal", md)
        # O marcador não vira turno no JSONL (contrato com o vault).
        self.assertFalse(any("sem texto" in row.get("text", "") for row in analysis if row["type"] == "turn"))

    def test_short_empty_block_is_not_marked(self):
        model = ScriptedModel([[], [seg(0.1, 1.0, " oi ")]])
        md, _, _, _ = self.run_main(model, {
            "mic": [{"start": 0, "end": 2 * SR}],   # 2 s de fala: abaixo de 3 s
            "system": [{"start": 0, "end": 2 * SR}],
        })
        self.assertNotIn("[sem texto", md)


# ---------------------------------------------------------------------------
# F6b — rótulo do prompt não vaza
# ---------------------------------------------------------------------------

class PromptLeakTests(PipelineHarness):
    def test_strip_prompt_echo_removes_legacy_label_anywhere(self):
        text, _, removed = tm.strip_prompt_echo(
            "Então fechamos. Contexto anterior recente: o cliente pediu prazo", None,
        )
        self.assertTrue(removed)
        self.assertNotIn("Contexto anterior", text)
        self.assertEqual(text, "Então fechamos. o cliente pediu prazo")

    def test_strip_prompt_echo_removes_prefix_repeating_the_prompt_tail(self):
        prompt = "Reunião de trabalho em português brasileiro. a proposta vai para o comitê na quinta"
        text, words, removed = tm.strip_prompt_echo(
            "a proposta vai para o comitê na quinta. Agora o orçamento.", prompt,
        )
        self.assertTrue(removed)
        self.assertEqual(words, 8)
        self.assertEqual(text, "Agora o orçamento.")

    def test_strip_prompt_echo_keeps_short_coincidences(self):
        prompt = "Reunião de trabalho em português brasileiro. eu acho que a gente precisa ver"
        text, _, removed = tm.strip_prompt_echo("eu acho que a gente consegue amanhã", prompt)
        self.assertFalse(removed)   # 5 palavras iguais: abaixo do mínimo, fica
        self.assertEqual(text, "eu acho que a gente consegue amanhã")

    def test_collect_segments_marks_turn_when_prompt_prefix_is_removed(self):
        prompt = "Reunião de trabalho em português brasileiro. o time valida o fluxo novo de cadastro"
        raw = [seg(0.0, 3.0, " o time valida o fluxo novo de cadastro e depois testa ")]
        report = {}

        segments = tm.collect_segments(raw, "Você", 0.0, tm.TranscriptionConfig(), prompt=prompt, report=report)
        turn = tm.turn_from_segments(segments)

        self.assertEqual(segments[0].text, "e depois testa")
        self.assertTrue(segments[0].prompt_echo_removed)
        self.assertTrue(turn.is_suspect)
        self.assertEqual(turn.text, "e depois testa")   # sem [inaudível]: o resto é fala
        self.assertEqual(report, {"prompt_echo_removed": 1})
        self.assertIn("prompt_echo_removed", tm.quality_flags_for_turn(turn, turn.text, turn.text, turn.text))
        self.assertIn("⚠ suspeito", tm.turn_markdown_text(turn))

    def test_no_output_contains_the_legacy_label(self):
        label = tm.LEGACY_PROMPT_LABEL
        model = ScriptedModel([
            [seg(0.1, 1.5, " primeira parte da conversa ")],
            [seg(0.1, 3.0, f" {label} primeira parte da conversa e segue o assunto ")],
            [seg(0.1, 1.0, f" {label} ")],
        ])
        md, analysis, jsonl, stdout = self.run_main(model, {
            "mic": [{"start": 0, "end": 2 * SR}, {"start": 8 * SR, "end": 12 * SR}],
            "system": [{"start": 0, "end": 2 * SR}],
        })

        for output in (md, json.dumps(analysis, ensure_ascii=False), json.dumps(jsonl, ensure_ascii=False)):
            self.assertNotIn("Contexto anterior recente", output)
        for call in model.calls:
            self.assertNotIn("Contexto anterior", call["initial_prompt"] or "")
        self.assertIn("e segue o assunto", md)


# ---------------------------------------------------------------------------
# F6c — linha do tempo única e duração real
# ---------------------------------------------------------------------------

class TimelineTests(PipelineHarness):
    def test_negative_system_offset_produces_monotonic_non_negative_timeline(self):
        model = ScriptedModel([
            [seg(0.1, 1.5, " fala do mic ")],
            [seg(0.1, 1.0, " fala do sistema cedo ")],
            [seg(0.1, 1.0, " fala do sistema depois ")],
        ])
        md, analysis, jsonl, _ = self.run_main(
            model,
            {
                "mic": [{"start": 2 * SR, "end": 4 * SR}],
                "system": [{"start": 1 * SR, "end": 3 * SR}, {"start": 600 * SR, "end": 602 * SR}],
            },
            extra_args=["--sys-offset", "-594000"],
            mic_sec=20.0,
            system_sec=620.0,
        )

        turns = [row for row in analysis if row["type"] == "turn"]
        self.assertTrue(all(row["start_ms"] >= 0 for row in turns))
        stamps = [m for m in re.findall(r"\] ?|\[(-?\d+:\d+)\]", md) if m]
        seconds = [int(stamp.split(":")[0]) * 60 + int(stamp.split(":")[1]) for stamp in stamps]
        self.assertEqual(seconds, sorted(seconds))
        self.assertNotIn("[-", md)
        meta = analysis[0]
        # Sistema começou 594 s antes: origem nele; o mic fica em +594 s.
        self.assertEqual(meta["track_offsets_ms"], {"mic": 594000.0, "system": 0.0})
        self.assertEqual(meta["audio_duration_ms"], 620000)
        self.assertIn("**Duração:** 10:20", md)
        self.assertEqual(jsonl[0]["audio_duration_ms"], 620000)

    def test_markdown_duration_falls_back_to_last_turn_without_audio_duration(self):
        turns = [tm.Turn("Você", "oi", 0, 61000, 0.9, False)]
        self.assertIn("**Duração:** 01:01", tm.build_markdown("t", turns, True, "pt"))
        self.assertIn(
            "**Duração:** 10:00",
            tm.build_markdown("t", turns, True, "pt", audio_duration_ms=600000),
        )


# ---------------------------------------------------------------------------
# F6d — eco entre trilhas
# ---------------------------------------------------------------------------

class EchoTests(PipelineHarness):
    def turns(self, mic_text, system_text, mic_start=10500, system_start=10000):
        return [
            tm.Turn("Interlocutor", system_text, system_start, system_start + 3000, 0.9, False, track="system"),
            tm.Turn("Você", mic_text, mic_start, mic_start + 3000, 0.9, False, track="mic"),
        ]

    def test_mic_turn_identical_to_system_half_second_before_is_marked(self):
        text = "a gente precisa revisar o contrato antes de sexta"
        turns = self.turns(text, text)

        share = tm.mark_echo_turns(turns)

        self.assertTrue(turns[1].echo_of_system)
        self.assertFalse(turns[0].echo_of_system)
        self.assertEqual(share, 1.0)
        self.assertEqual(turns[1].text, text)   # não apaga texto

    def test_mic_turn_with_twenty_percent_shared_trigrams_is_not_marked(self):
        system_text = "um dois três quatro cinco seis sete"
        # 12 palavras = 10 trigramas; 2 deles ("um dois três", "dois três quatro") no sistema.
        mic_text = "um dois três quatro oito nove dez onze doze treze quatorze quinze"
        self.assertAlmostEqual(signals.echo_share(mic_text, [system_text]), 0.2)

        turns = self.turns(mic_text, system_text)
        tm.mark_echo_turns(turns)

        self.assertFalse(turns[1].echo_of_system)

    def test_echo_window_limits(self):
        text = "a gente precisa revisar o contrato antes de sexta"
        # Mic 3 s depois do fim do sistema ainda conta; 5 s depois, não.
        near = self.turns(text, text, mic_start=16000, system_start=10000)
        far = self.turns(text, text, mic_start=18000, system_start=10000)
        tm.mark_echo_turns(near)
        tm.mark_echo_turns(far)
        self.assertTrue(near[1].echo_of_system)
        self.assertFalse(far[1].echo_of_system)

    def test_pipeline_marks_echo_in_markdown_and_analysis(self):
        text = " o deploy de homologação sai amanhã cedo "
        model = ScriptedModel([
            [seg(0.6, 3.0, text)],   # mic: repete o sistema 0,5 s depois
            [seg(0.1, 2.5, text)],   # sistema
        ])
        md, analysis, jsonl, _ = self.run_main(model, {
            "mic": [{"start": 0, "end": 4 * SR}],
            "system": [{"start": 0, "end": 4 * SR}],
        })

        self.assertIn("**(eco provável) Você:** [00:00]", md)
        self.assertIn('eco provável: 100% das palavras de "Você"', md)
        turns = [row for row in analysis if row["type"] == "turn"]
        mic_row = next(row for row in turns if row["track"] == "mic")
        sys_row = next(row for row in turns if row["track"] == "system")
        self.assertIs(mic_row["echo_of_system"], True)
        self.assertNotIn("echo_of_system", sys_row)
        # O rótulo do turno não muda (compatibilidade com o vault).
        self.assertEqual(mic_row["speaker"], "Você")
        self.assertTrue(all(row.get("speaker") in ("Você", "Interlocutor") for row in jsonl[1:]))


# ---------------------------------------------------------------------------
# F6e — costura sem duplicação
# ---------------------------------------------------------------------------

class SeamTests(PipelineHarness):
    def test_overlap_seam_does_not_repeat_previous_final_words(self):
        wav_path = self.write_wav(31.0)
        first_text = "vamos alinhar o cronograma da entrega com o time de dados"
        second_text = "com o time de dados e depois apresentamos ao cliente"
        # Chunk 1: 1–21 s; chunk 2 fatiado em 19 s (22 - 3 de overlap).
        # A frase repetida no chunk 2 ocupa 0–2,1 s do recorte = 19–21,1 s.
        model = ScriptedModel([
            [seg(14.0, 20.0, f" {first_text} ", words=even_words(14.0, 20.0, first_text))],
            [seg(0.0, 7.0, f" {second_text} ", words=(
                even_words(0.0, 2.1, "com o time de dados") + even_words(2.4, 7.0, "e depois apresentamos ao cliente")
            ))],
        ])
        report = {}
        with patch.object(tm, "detect_speech_islands", return_value=[
            {"start": 1 * SR, "end": 21 * SR},
            {"start": 22 * SR, "end": 30 * SR},
        ]):
            segments = tm.transcribe_track(wav_path, "Você", model, quality_report=report)

        turns = tm.consolidate_turns(segments)
        full_text = " ".join(turn.text for turn in turns)
        self.assertEqual(full_text, f"{first_text} e depois apresentamos ao cliente")
        self.assertEqual(report["seam_words_dropped"], 5)
        self.assertEqual(report["seam_segments_trimmed"], 1)
        duplicated, _ = signals.seam_duplicate_pairs(
            [("mic", turn.start_ms, turn.end_ms, turn.text) for turn in turns]
        )
        self.assertEqual(duplicated, 0)

    def test_seam_duplicate_pairs_counts_repeated_heads(self):
        turns = [
            ("mic", 0, 1000, "vamos alinhar o cronograma com o time de dados"),
            ("mic", 1500, 3000, "com o time de dados e depois seguimos"),
            ("mic", 4000, 5000, "outra coisa totalmente diferente aqui"),
        ]
        self.assertEqual(signals.seam_duplicate_pairs(turns), (1, 2))

    def test_shared_phrase_in_the_middle_is_not_a_seam_duplicate(self):
        turns = [
            ("mic", 0, 1000, "eu acho que a gente precisa ver isso com calma"),
            ("mic", 1500, 3000, "bom então eu acho que a gente consegue amanhã"),
        ]
        self.assertEqual(signals.seam_duplicate_pairs(turns), (0, 1))
        # Até 3 palavras de folga antes da repetição ainda contam.
        self.assertTrue(signals.repeats_tail(
            signals.tokens("fechamos o escopo da fase dois"), signals.tokens("é então o escopo da fase dois e o prazo"),
        ))


# ---------------------------------------------------------------------------
# F6f — idioma fixo com alerta
# ---------------------------------------------------------------------------

class FixedLanguageCheckTests(PipelineHarness):
    def test_english_audio_with_fixed_portuguese_is_flagged_without_switching(self):
        model = ScriptedModel(
            [[seg(0.1, 9.0, " hello everyone let's start ")], [seg(0.1, 9.0, " yes let's go ")]],
            languages=["en", "en"],
        )
        md, analysis, _, _ = self.run_main(model, {
            "mic": [{"start": 0, "end": 10 * SR}],
            "system": [{"start": 0, "end": 10 * SR}],
        })

        meta = analysis[0]
        self.assertIs(meta["lang_mismatch"], True)
        check = meta["transcription_diagnostics"]["mic"]["language_check"]
        self.assertEqual((check["expected"], check["detected"], check["mismatch"]), ("pt", "en", True))
        self.assertTrue(all(call["language"] == "pt" for call in model.calls))   # não troca
        self.assertIn("idioma: mic parece en (fixo pt), sistema parece en (fixo pt)", md)

    def test_matching_language_reports_no_divergence(self):
        model = ScriptedModel([[seg(0.1, 9.0, " bom dia ")], [seg(0.1, 9.0, " bom dia a todos ")]])
        _, analysis, _, _ = self.run_main(model, {
            "mic": [{"start": 0, "end": 10 * SR}],
            "system": [{"start": 0, "end": 10 * SR}],
        })
        self.assertIs(analysis[0]["lang_mismatch"], False)

    def test_low_share_divergence_is_not_flagged(self):
        audio = np.full(60 * SR, 0.1, dtype=np.float32)
        chunks = [{"start": 0, "end": 20 * SR}, {"start": 21 * SR, "end": 31 * SR}]
        model = ScriptedModel([], languages=["en", "pt"])   # 20 s en, 9 s pt (amostra de 30 s)

        result = tm.check_fixed_language(model, audio, chunks, "pt")

        self.assertEqual(result["detected"], "en")
        self.assertFalse(result["mismatch"])   # 69% dos votos: abaixo de 80%
        self.assertEqual(tm.language_sample_chunks(chunks)[-1], {"start": 21 * SR, "end": 31 * SR})

    def test_sample_is_limited_to_first_thirty_seconds_of_speech(self):
        chunks = [{"start": i * 30 * SR, "end": i * 30 * SR + 25 * SR} for i in range(4)]
        sample = tm.language_sample_chunks(chunks)
        self.assertEqual(sum(item["end"] - item["start"] for item in sample), 30 * SR)
        self.assertEqual(len(sample), 2)


# ---------------------------------------------------------------------------
# F6g — caixa de confiança e marcação por segmento
# ---------------------------------------------------------------------------

class ConfidenceBoxTests(PipelineHarness):
    def clean_turns(self):
        return [
            tm.Turn("Você", "bom dia a todos", 0, 2000, 0.9, False, track="mic"),
            tm.Turn("Interlocutor", "bom dia vamos começar", 2500, 5000, 0.9, False, track="system"),
        ]

    def test_box_is_absent_when_capture_is_complete_and_nothing_to_report(self):
        box = tm.build_confidence_box(
            self.clean_turns(), dual_track=True, tracks="both", capture_integrity="complete",
            language_checks={"mic": {"mismatch": False}}, echo_share=0.0,
        )
        self.assertEqual(box, [])

    def test_legacy_markdown_is_unchanged_without_new_data(self):
        turns = [
            tm.Turn("Você", "texto", 0, 1000, 0.9, False),
            tm.Turn("Interlocutor", "talvez", 1500, 3000, 0.3, True),
        ]
        legacy = tm.build_markdown("Teste", turns, True, "pt", recorded_at="2026-10-07T09:00:00-03:00")
        box = ["> Confiança: x", "> Lacunas: y", "> Qualidade: z"]
        with_box = tm.build_markdown(
            "Teste", turns, True, "pt", recorded_at="2026-10-07T09:00:00-03:00", confidence_box=box,
        )

        self.assertIn("**Interlocutor:** [00:01] talvez ⚠ suspeito", legacy)
        self.assertEqual(with_box.replace("\n" + "\n".join(box) + "\n\n", "\n"), legacy)
        self.assertLess(with_box.index("> Confiança:"), with_box.index("---"))
        self.assertTrue(with_box.startswith("# Teste\n"))

    def test_capture_loss_line_shows_position_and_amount(self):
        model = ScriptedModel([[seg(0.1, 1.5, " oi ")], [seg(0.1, 1.0, " olá ")]])
        md, analysis, _, _ = self.run_main(
            model,
            {"mic": [{"start": 0, "end": 2 * SR}], "system": [{"start": 0, "end": 2 * SR}]},
            extra_args=["--capture-integrity", "degraded", "--capture-loss", "mic:start:0.0:6.7"],
        )

        self.assertIn("> Lacunas: mic 6 s no início (00:00–00:06)", md)
        self.assertIn("> Confiança: falantes: Você = microfone; Remotos (não separados) = áudio do sistema", md)
        self.assertEqual(
            analysis[0]["loss_intervals"],
            [{"track": "mic", "kind": "start", "at_s": 0.0, "dur_s": 6.7}],
        )
        # Rótulo dos turnos continua "Interlocutor".
        self.assertIn("**Interlocutor:** [00:00] olá", md)

    def test_without_capture_loss_argument_behavior_is_unchanged(self):
        model = ScriptedModel([[seg(0.1, 1.5, " oi ")], [seg(0.1, 1.0, " olá ")]])
        md, analysis, _, _ = self.run_main(
            model, {"mic": [{"start": 0, "end": 2 * SR}], "system": [{"start": 0, "end": 2 * SR}]},
            extra_args=["--capture-integrity", "complete"],
        )
        self.assertNotIn("> Confiança:", md)
        self.assertNotIn("loss_intervals", analysis[0])

    def test_invalid_capture_loss_exits_with_code_two_and_clear_message(self):
        for bad in ("mic:start:0.0", "speaker:start:0:1", "mic:middle:0:1", "mic:gap:x:1", "mic:gap:3:-1", "mic:gap:-1:2", "mic:gap:nan:1"):
            with self.subTest(bad=bad):
                stderr = io.StringIO()
                argv = ["transcribe_meeting.py", "--mic", "/tmp/x.wav", "--out", "/tmp", "--capture-loss", bad]
                with patch.object(sys, "argv", argv), patch("sys.stderr", stderr), \
                        self.assertRaises(SystemExit) as raised:
                    tm.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("--capture-loss inválido", stderr.getvalue())

    def test_capture_loss_kinds_and_durations_are_described(self):
        self.assertEqual(
            tm.describe_capture_loss({"track": "system", "kind": "gap", "at_s": 860.0, "dur_s": 3.2}),
            "sistema 3 s no meio (14:20–14:23)",
        )
        self.assertEqual(tm.format_duration_label(95), "1 min 35 s")
        self.assertEqual(tm.format_duration_label(0.4), "<1 s")
        # O app formata com %.1f: perda < 0,05 s chega como 0.0 e não pode derrubar o job.
        self.assertEqual(tm.parse_capture_loss("system:gap:12.0:0.0")["dur_s"], 0.0)

    def test_suspect_mark_is_per_segment_with_decoder_signals(self):
        raw = [
            seg(0.0, 2.0, " parte confiável "),
            seg(2.1, 4.0, " parte com fallback ", temperature=0.4),
            seg(4.1, 6.0, " parte final ok "),
        ]
        segments = tm.collect_segments(raw, "Você", 0.0, tm.TranscriptionConfig())
        turn = tm.consolidate_turns(segments)[0]

        self.assertEqual(
            tm.turn_markdown_text(turn),
            "parte confiável parte com fallback ⚠ suspeito parte final ok",
        )
        self.assertEqual(turn.temperature, 0.4)

    def test_low_confidence_turn_without_decoder_signal_is_not_marked_in_markdown(self):
        # avg_logprob -0,6 dá confiança 0,55 (< 0,6): o JSONL continua suspeito,
        # mas o .md só marca com logprob < -0,8, temperatura, compressão ou no_speech.
        raw = [seg(0.0, 2.0, " frase razoável ", avg_logprob=-0.6)]
        turn = tm.consolidate_turns(tm.collect_segments(raw, "Você", 0.0, tm.TranscriptionConfig()))[0]

        self.assertTrue(turn.is_suspect)
        self.assertEqual(tm.turn_markdown_text(turn), "frase razoável")

    def test_compression_ratio_and_no_speech_mark_the_segment(self):
        for extra in ({"compression_ratio": 2.6}, {"no_speech_prob": 0.7}, {"avg_logprob": -0.9}):
            with self.subTest(**extra):
                segments = tm.collect_segments([seg(0.0, 2.0, " texto ", **extra)], "Você", 0.0, tm.TranscriptionConfig())
                self.assertTrue(tm.segment_marked_suspect(segments[0]))

    def test_analysis_persists_decoder_signals(self):
        model = ScriptedModel([
            [seg(0.1, 1.5, " oi ", temperature=0.2, compression_ratio=1.31234)],
            [seg(0.1, 1.0, " olá ")],
        ])
        _, analysis, _, _ = self.run_main(model, {
            "mic": [{"start": 0, "end": 2 * SR}], "system": [{"start": 0, "end": 2 * SR}],
        })
        mic_row = next(row for row in analysis if row["type"] == "turn" and row["track"] == "mic")
        sys_row = next(row for row in analysis if row["type"] == "turn" and row["track"] == "system")
        self.assertEqual((mic_row["temperature"], mic_row["compression_ratio"]), (0.2, 1.312))
        self.assertNotIn("temperature", sys_row)

    def test_mlx_backend_forwards_temperature_and_compression_ratio(self):
        def fake_transcribe(audio_input, **kwargs):
            return {"segments": [{
                "start": 0.0, "end": 1.0, "text": " ok ", "avg_logprob": -0.2,
                "no_speech_prob": 0.1, "temperature": 0.2, "compression_ratio": 1.4,
            }], "language": "pt"}

        fake_hub = SimpleNamespace(snapshot_download=lambda repo, local_files_only: "/cached")
        with patch.dict(sys.modules, {"huggingface_hub": fake_hub, "mlx_whisper": SimpleNamespace(transcribe=fake_transcribe)}):
            segments, _ = tm.MlxBackend("mlx-community/test").transcribe(np.zeros(SR, dtype=np.float32))

        self.assertEqual((segments[0].temperature, segments[0].compression_ratio), (0.2, 1.4))

    def test_box_quality_line_counts_retries_and_removals(self):
        box = tm.build_confidence_box(
            self.clean_turns(), dual_track=True, tracks="both", capture_integrity="complete",
            quality_reports={
                "mic": {"coverage_retries_used": 2, "prompt_echo_removed": 1},
                "system": {"seam_segments_trimmed": 3, "coverage_retries_used": 1},
            },
            language_checks={"mic": {"mismatch": False}},
            echo_share=0.12,
        )
        self.assertEqual(len(box), 3)
        self.assertEqual(
            box[0],
            '> Confiança: falantes: Você = microfone; Remotos (não separados) = áudio do sistema'
            ' · eco provável: 12% das palavras de "Você"',
        )
        self.assertEqual(box[1], "> Lacunas: captura sem lacunas medidas; fala sem texto: nenhuma · idioma: sem divergência")
        self.assertEqual(
            box[2],
            "> Qualidade: 0% do texto com baixa confiança · trechos reprocessados sem vocabulário: 3"
            " · prompt/duplicação removidos: 4",
        )


if __name__ == "__main__":
    unittest.main()
