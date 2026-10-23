from __future__ import annotations


import io
import json
import sys
import unittest
import urllib.error
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import transcribe_meeting as tm


class FakeResponse:
    def __init__(self, payload: dict):
        self._body = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code: int, retry_after: str | None = None):
    headers = {"retry-after": retry_after} if retry_after else {}
    return urllib.error.HTTPError(tm.GROQ_API_URL, code, "erro", headers, io.BytesIO(b"segredo ecoado"))


class GroqBackendTests(unittest.TestCase):
    def backend(self, responses, sleeps=None):
        calls = []

        def urlopen(request, timeout):
            calls.append(request)
            outcome = responses.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return FakeResponse(outcome)

        backend = tm.GroqBackend(
            api_key="chave-de-teste", urlopen=urlopen,
            sleep=(sleeps.append if sleeps is not None else lambda _: None),
        )
        return backend, calls

    def test_request_carries_prompt_language_and_word_timestamps(self):
        backend, calls = self.backend([{
            "language": "Portuguese",
            "segments": [
                {"start": 0.0, "end": 1.5, "text": " Bom dia", "avg_logprob": -0.2, "no_speech_prob": 0.01},
                {"start": 1.5, "end": 3.0, "text": " pessoal", "avg_logprob": -0.3, "no_speech_prob": 0.02},
            ],
            "words": [
                {"word": "Bom", "start": 0.1, "end": 0.4},
                {"word": "dia", "start": 0.5, "end": 0.9},
                {"word": "pessoal", "start": 1.6, "end": 2.4},
            ],
        }])
        segments, info = backend.transcribe(
            np.zeros(tm.SAMPLE_RATE * 3, dtype=np.float32),
            language="pt", initial_prompt="Reunião de produto.", hotwords="Acme",
            word_timestamps=True, beam_size=5,
        )

        request = calls[0]
        self.assertEqual(request.full_url, tm.GROQ_API_URL)
        self.assertEqual(request.get_header("Authorization"), "Bearer chave-de-teste")
        body = request.data
        self.assertIn(b'name="prompt"\r\n\r\nReuni\xc3\xa3o de produto. Acme\r\n', body)
        self.assertIn(b'name="language"\r\n\r\npt\r\n', body)
        self.assertEqual(body.count(b'name="timestamp_granularities[]"'), 2)
        self.assertIn(b"RIFF", body)
        self.assertNotIn(b"beam_size", body)

        self.assertEqual([seg.text for seg in segments], [" Bom dia", " pessoal"])
        self.assertEqual([w["word"] for w in segments[0].words], ["Bom", "dia"])
        self.assertEqual(info.language, "pt")
        self.assertEqual(backend.requests, 1)
        self.assertEqual(backend.billed_seconds, 10.0)   # mínimo por requisição

    def test_segments_come_back_on_the_session_timeline(self):
        backend, _ = self.backend([{
            "segments": [{"start": 0.5, "end": 2.0, "text": " olá", "avg_logprob": -0.1, "no_speech_prob": 0.0}],
            "words": [{"word": "olá", "start": 0.6, "end": 1.0}],
        }])
        raw, _ = backend.transcribe(np.zeros(tm.SAMPLE_RATE * 2, dtype=np.float32), word_timestamps=True)
        segments = tm.collect_segments(raw, "Interlocutor", 100.0, tm.TranscriptionConfig())
        self.assertAlmostEqual(segments[0].start, 100.5)
        self.assertEqual(segments[0].words[0][:2], (100.6, 101.0))

    def test_silence_segments_are_dropped_like_local_whisper(self):
        backend, _ = self.backend([{
            "segments": [
                {"start": 0.0, "end": 1.0, "text": " Obrigado.", "avg_logprob": -1.2, "no_speech_prob": 0.9},
                {"start": 1.0, "end": 2.0, "text": " certo", "avg_logprob": -0.2, "no_speech_prob": 0.9},
            ],
        }])
        segments, _ = backend.transcribe(np.zeros(tm.SAMPLE_RATE * 2, dtype=np.float32))
        self.assertEqual([seg.text for seg in segments], [" certo"])

    def test_rate_limit_waits_and_retries(self):
        sleeps = []
        backend, calls = self.backend([http_error(429, "3"), {"segments": []}], sleeps)
        backend.transcribe(np.zeros(tm.SAMPLE_RATE, dtype=np.float32))
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [3.0])

    def test_client_error_fails_without_echoing_the_body(self):
        backend, calls = self.backend([http_error(401)])
        with self.assertRaises(RuntimeError) as ctx:
            backend.transcribe(np.zeros(tm.SAMPLE_RATE, dtype=np.float32))
        self.assertEqual(len(calls), 1)
        self.assertIn("401", str(ctx.exception))
        self.assertNotIn("segredo", str(ctx.exception))

    def test_detect_language_maps_names_to_codes(self):
        backend, _ = self.backend([{"language": "English"}])
        self.assertEqual(backend.detect_language(np.zeros(tm.SAMPLE_RATE, dtype=np.float32)), "en")

    def test_wav_bytes_is_16k_mono_pcm(self):
        data = tm.wav_bytes(np.array([0.0, 0.5, -2.0], dtype=np.float32))
        with wave.open(io.BytesIO(data)) as handle:
            self.assertEqual((handle.getframerate(), handle.getnchannels(), handle.getsampwidth()), (16000, 1, 2))
            frames = np.frombuffer(handle.readframes(3), dtype=np.int16)
        self.assertEqual(frames[2], -32767)

    def test_key_comes_from_env_before_keychain(self):
        with patch.dict("os.environ", {"GROQ_API_KEY": "  do-ambiente "}), \
                patch("subprocess.run") as run:
            self.assertEqual(tm.groq_api_key(), "do-ambiente")
            run.assert_not_called()

    def test_missing_key_is_a_clear_error(self):
        result = type("R", (), {"returncode": 44, "stdout": ""})()
        with patch.dict("os.environ", {}, clear=True), patch("subprocess.run", return_value=result):
            with self.assertRaises(RuntimeError) as ctx:
                tm.groq_api_key()
        self.assertIn(tm.GROQ_KEYCHAIN_SERVICE, str(ctx.exception))

    def test_cli_refuses_groq_without_explicit_consent(self):
        argv = ["transcribe_meeting.py", "--backend", "groq", "--system", "x.wav"]
        with patch.object(sys, "argv", argv), patch("sys.stderr", new=io.StringIO()) as err:
            with self.assertRaises(SystemExit):
                tm.main()
        self.assertIn("--allow-cloud-asr", err.getvalue())


if __name__ == "__main__":
    unittest.main()
