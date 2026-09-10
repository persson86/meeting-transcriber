#!/usr/bin/env python3
# Run with: .venv/bin/python transcribe_meeting.py [args]  (venv do projeto; ver requirements.txt)
"""
Transcreve duas trilhas de áudio (mic + sistema) e mescla por timestamp em Markdown.
Diarização grátis: trilha mic = "Você", trilha system = "Interlocutor".
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import wave
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import noisereduce as nr
from scipy.io import wavfile

SAMPLE_RATE = 16000

VAD_PARAMETERS = dict(
    min_speech_duration_ms=150,   # captura backchannels PT-BR curtos ("sim", "aham")
    min_silence_duration_ms=800,
    speech_pad_ms=400,
)

CHUNK_VAD_PARAMETERS = dict(
    min_speech_duration_ms=120,
    min_silence_duration_ms=800,
    speech_pad_ms=400,
    max_speech_duration_s=28.0,
)
CHUNK_MAX_GAP_SEC = 3.5
CHUNK_MAX_SPAN_SEC = 28.0
CHUNK_OVERLAP_SEC = 3.0
CHUNK_DEDUP_TOLERANCE_SEC = 0.5
TEXT_DENSITY_SUSPECT_CHARS_PER_SEC = 80.0

PIPELINE_VERSION = "0.7.0"
DEFAULT_HOTWORD_LIMIT = 60
PROMPT_TAIL_MAX_CHARS = 240
RUNAWAY_UNICODE_MIN_REPEATS = 8

_last_progress = -1


# ---------------------------------------------------------------------------
# Memory profiling (opt-in via --profile-memory; logs vão para stderr para não
# poluir a linha "Output:" do stdout que o app Swift parseia)
# ---------------------------------------------------------------------------

def _rss_mb() -> float:
    """RSS do processo atual em MB. Usa `ps` para evitar ambiguidade de unidade
    do resource.ru_maxrss entre plataformas."""
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())])
    return int(out) / 1024.0


def _mem(tag: str, enabled: bool) -> None:
    if enabled:
        print(f"[mem] {tag} rss={_rss_mb():.0f}MB", file=sys.stderr, flush=True)


def emit_progress(pct: int) -> None:
    global _last_progress
    pct = max(0, min(100, int(pct)))
    if pct <= _last_progress:
        return
    _last_progress = pct
    print(f"PROGRESS: {pct}", flush=True)


def audio_duration_sec(path: str | None) -> float:
    if not path:
        return 0.0
    try:
        with wave.open(path, "rb") as audio:
            return audio.getnframes() / float(audio.getframerate())
    except Exception:
        return 0.0


def _mlx_peak_mb() -> float | None:
    """Pico de memória alocada pelo MLX (unified/Metal). RSS não captura os buffers
    Metal, então este é o número real de memória do modelo no backend mlx."""
    try:
        import mlx.core as mx
        return mx.get_peak_memory() / 1e6
    except Exception:
        return None


@dataclass
class Segment:
    start: float
    end: float
    text: str
    speaker: str  # "Você" | "Interlocutor" | ""
    avg_logprob: float | None = None
    no_speech_prob: float | None = None
    raw_text: str | None = None
    text_is_suspect: bool = False


@dataclass
class Turn:
    speaker: str
    text: str
    start_ms: int
    end_ms: int
    confidence: float
    is_suspect: bool
    raw_text: str | None = None
    safe_text: str | None = None
    track: str | None = None


@dataclass
class SpeakerCluster:
    label: str
    centroid: tuple[float, float, float]
    count: int = 1


@dataclass
class TranscriptionConfig:
    language: str = "pt"
    context_terms: list[str] | None = None
    replacements: dict[str, str] | None = None
    hotwords: list[str] | None = None
    known_names: list[str] | None = None

    def __post_init__(self) -> None:
        self.context_terms = self.context_terms or []
        self.replacements = self.replacements or {}
        self.hotwords = self.hotwords or []
        self.known_names = self.known_names or []


# ---------------------------------------------------------------------------
# Language configuration
# ---------------------------------------------------------------------------

LANGUAGE_CONFIG = {
    "pt": {
        "whisper_lang": "pt",
        "base_prompt": "Reunião de trabalho em português brasileiro.",
        "default_hotwords": (
            "Azure",
            "UAT",
            "Dev",
            "homologação",
            "staging",
            "VNet",
            "Kubernetes",
            "namespace",
            "DevOps",
            "SRE",
            "Cloud",
            "endpoint",
            "backend",
            "frontend",
            "API",
            "JSON",
            "Markdown",
            "custom metadata",
            "worker",
            "subscription",
            "webhook",
            "database",
            "deploy",
            "produção",
            "pull request",
            "sprint",
            "roadmap",
            "GPT",
            "Claude",
            "LLM",
            "MCP",
            "RAG",
            "Databricks",
            "data lake",
        ),
        "default_replacements": {
            "OAT": "UAT",
            "SandPoint": "endpoint",
            "subscript ion": "subscription",
            "subscription ion": "subscription",
            "subscript": "subscription",
            "subscriptionion": "subscription",
            "Squatch": "Squad",
            "Splat": "Squad",
            "ponta desse bag": "ponta do iceberg",
        },
    },
    "en": {
        "whisper_lang": "en",
        "base_prompt": "Business meeting in English.",
    },
    "auto": {
        "whisper_lang": None,
        "base_prompt": None,
    },
}


def get_lang_config(language: str) -> dict:
    return LANGUAGE_CONFIG.get(language, LANGUAGE_CONFIG["pt"])


def build_initial_prompt(config: TranscriptionConfig) -> str | None:
    """Monta um prompt curto; termos técnicos ficam em hotwords."""
    lang_cfg = get_lang_config(config.language)
    return lang_cfg["base_prompt"] or None


def default_hotwords_for_language(language: str) -> list[str]:
    raw_terms = get_lang_config(language).get("default_hotwords", ())
    if isinstance(raw_terms, str):
        return [term.strip() for term in raw_terms.split(",") if term.strip()]
    return [str(term).strip() for term in raw_terms if str(term).strip()]


def build_hotwords(config: TranscriptionConfig, limit: int = DEFAULT_HOTWORD_LIMIT) -> str | None:
    """Prioriza termos da reunião e completa com poucos termos padrão."""
    raw_terms = [*config.context_terms, *config.hotwords]
    raw_terms.extend(default_hotwords_for_language(config.language))

    hotwords = []
    seen = set()
    for term in raw_terms:
        normalized = term.strip()
        key = normalized.casefold()
        if not normalized or key in seen:
            continue
        seen.add(key)
        hotwords.append(normalized)
        if len(hotwords) >= limit:
            break

    return ", ".join(hotwords) if hotwords else None


def apply_text_replacements(text: str, replacements: dict[str, str]) -> str:
    """Aplica normalizações determinísticas e explícitas."""
    sources = [source for source in replacements if source]
    if not sources:
        return text
    pattern = re.compile(
        "|".join(re.escape(source) for source in sorted(sources, key=len, reverse=True))
    )
    return pattern.sub(lambda match: replacements[match.group(0)], text)


def default_replacements_for_language(language: str) -> dict[str, str]:
    return dict(get_lang_config(language).get("default_replacements", {}))


def normalize_known_names(text: str, known_names: list[str], threshold: float = 0.75) -> str:
    """Replace capitalized tokens that are sufficiently similar to a known name.

    Only applies to tokens of len >= 4 to avoid clobbering common short words.
    Uses SequenceMatcher (stdlib) — no extra deps.
    """
    from difflib import SequenceMatcher
    if not known_names:
        return text
    words = text.split()
    result = []
    for word in words:
        clean = re.sub(r"[^\w]", "", word, flags=re.UNICODE)
        if len(clean) >= 4 and clean[0].isupper():
            best_name: str | None = None
            best_ratio = 0.0
            for name in known_names:
                ratio = SequenceMatcher(None, clean.lower(), name.lower()).ratio()
                if ratio > best_ratio:
                    best_ratio = ratio
                    best_name = name
            if best_name is not None and best_ratio >= threshold:
                word = word.replace(clean, best_name)
        result.append(word)
    return " ".join(result)


def collapse_repeated_ngrams(text: str, min_repeats: int = 5, max_ngram: int = 4) -> str:
    """Colapsa loops como "Ferreira Ferreira..." ou "thumbs down thumbs down..."."""
    token_re = re.compile(r"\b\w+\b", flags=re.UNICODE)

    for ngram_size in range(max_ngram, 0, -1):
        tokens = list(token_re.finditer(text))
        if len(tokens) < ngram_size * min_repeats:
            continue

        normalized = [token.group(0).casefold() for token in tokens]
        replacements: list[tuple[int, int, str]] = []
        index = 0
        while index <= len(tokens) - ngram_size * min_repeats:
            phrase = normalized[index:index + ngram_size]
            repeat_count = 1
            next_index = index + ngram_size
            while (
                next_index + ngram_size <= len(tokens)
                and normalized[next_index:next_index + ngram_size] == phrase
            ):
                repeat_count += 1
                next_index += ngram_size

            if repeat_count >= min_repeats:
                start = tokens[index].start()
                first_end = tokens[index + ngram_size - 1].end()
                end = tokens[next_index - 1].end()
                replacements.append((start, end, text[start:first_end]))
                index = next_index
            else:
                index += 1

        if replacements:
            for start, end, replacement in reversed(replacements):
                text = f"{text[:start]}{replacement}{text[end:]}"

    return text


def token_has_runaway_substring(token: str, min_repeats: int = 4) -> bool:
    """Detecta repeticoes coladas dentro de um token, como KidsKidsKidsKids."""
    folded = token.casefold()
    max_unit = min(12, max(3, len(folded) // min_repeats))

    for start in range(len(folded)):
        for unit_size in range(3, max_unit + 1):
            end = start + unit_size
            if end + (unit_size * (min_repeats - 1)) > len(folded):
                continue
            unit = folded[start:end]
            if not unit.isalpha():
                continue

            count = 1
            pos = end
            while folded[pos:pos + unit_size] == unit:
                count += 1
                pos += unit_size
            if count >= min_repeats:
                return True
    return False


def text_has_runaway_repeated_unit(
    text: str,
    min_repeats: int = RUNAWAY_UNICODE_MIN_REPEATS,
    max_unit: int = 8,
) -> bool:
    """Detecta loops compactos em qualquer script, ex: "っぱっぱ..."."""
    compact = re.sub(r"\s+", "", text)
    if len(compact) < min_repeats * 2:
        return False

    max_unit = min(max_unit, max(1, len(compact) // min_repeats))
    for unit_size in range(1, max_unit + 1):
        for start in range(0, len(compact) - (unit_size * min_repeats) + 1):
            unit = compact[start:start + unit_size]
            if not unit.strip() or unit.isspace():
                continue
            if compact.startswith(unit * min_repeats, start):
                return True
    return False


def sanitize_intraword_runaways(text: str) -> tuple[str, bool]:
    """Substitui loops intra-token por [inaudivel] e retorna se houve suspeita."""
    changed = False

    def replace_token(match: re.Match) -> str:
        nonlocal changed
        token = match.group(0)
        if re.fullmatch(r"[Kk]{3,7}", token):
            return token
        if re.search(r"([A-Za-zÀ-ÿ])\1{7,}", token, flags=re.IGNORECASE):
            changed = True
            return "[inaudível]"
        if re.search(r"[Kk]{3,}", token):
            changed = True
            return "[inaudível]"
        if token_has_runaway_substring(token):
            changed = True
            return "[inaudível]"
        return token

    sanitized = re.sub(r"\b[A-Za-zÀ-ÿ0-9_]{3,}\b", replace_token, text)
    if text_has_runaway_repeated_unit(sanitized):
        return "[inaudível]", True
    return sanitized, changed


def normalize_laughter(text: str) -> str:
    """Normaliza riso textual curto sem esconder loops longos ja marcados."""
    return re.sub(r"\b[Kk]{3,7}\b", "[risos]", text)


def collapse_runaway_repetitions(text: str, max_repeats: int = 2) -> str:
    """Remove repetições consecutivas típicas de alucinação do Whisper."""
    text, _ = sanitize_intraword_runaways(text)
    text = collapse_repeated_ngrams(text)
    parts = re.findall(r"\s*([^.!?…]+[.!?…]+|[^.!?…]+$)", text)
    if len(parts) < max_repeats + 1:
        return text

    collapsed = []
    previous_norm = None
    repeat_count = 0
    suppressed_repeat = False
    for part in parts:
        stripped = part.strip()
        norm = re.sub(r"\W+", " ", stripped, flags=re.UNICODE).strip().casefold()
        if norm and norm == previous_norm:
            repeat_count += 1
        else:
            if suppressed_repeat and norm and previous_norm and previous_norm.startswith(norm):
                continue
            previous_norm = norm
            repeat_count = 1
            suppressed_repeat = False

        if repeat_count <= max_repeats:
            collapsed.append(stripped)
        else:
            suppressed_repeat = True

    return " ".join(collapsed)


def parse_replacement(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("Use o formato origem=destino")
    source, target = value.split("=", 1)
    source = source.strip()
    target = target.strip()
    if not source:
        raise argparse.ArgumentTypeError("A origem da substituição não pode ser vazia")
    return source, target


def parse_speaker_map(value: str) -> dict[str, str]:
    """Converte "Remote_A=Alex,Remote_B=Jordan" em dict label→nome."""
    mapping: dict[str, str] = {}
    for pair in value.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            raise argparse.ArgumentTypeError(
                "Use o formato Label=Nome[,Label=Nome...] (ex: Remote_A=Alex)"
            )
        label, name = pair.split("=", 1)
        label = label.strip()
        name = name.strip()
        if not label or not name:
            raise argparse.ArgumentTypeError(
                "Label e nome não podem ser vazios em --speaker-map"
            )
        mapping[label] = name
    return mapping


def parse_metadata_pair(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("Use o formato chave=valor")
    key, raw_value = value.split("=", 1)
    key = key.strip()
    raw_value = raw_value.strip()
    if not key or not raw_value:
        raise argparse.ArgumentTypeError("Chave e valor não podem ser vazios")
    return key, raw_value


def load_transcription_config(
    language: str,
    config_json: str | None,
    context_terms: list[str] | None,
    replacement_pairs: list[tuple[str, str]] | None,
    hotwords: list[str] | None = None,
    use_default_replacements: bool = True,
) -> TranscriptionConfig:
    config = TranscriptionConfig(language=language)
    if use_default_replacements:
        config.replacements.update(default_replacements_for_language(language))

    if config_json:
        raw = json.loads(Path(config_json).read_text(encoding="utf-8"))
        config.context_terms.extend(raw.get("context_terms", []))
        config.replacements.update(raw.get("replacements", {}))
        config.hotwords.extend(raw.get("hotwords", []))
        config.known_names.extend(raw.get("known_names", []))

    config.context_terms.extend(context_terms or [])
    config.replacements.update(dict(replacement_pairs or []))
    config.hotwords.extend(hotwords or [])
    return config


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------

def normalize_audio(data: np.ndarray) -> np.ndarray:
    """Converte WAV mono/stereo para float32 mono normalizado."""
    if np.issubdtype(data.dtype, np.floating):
        normalized = data.astype(np.float32)
    else:
        info = np.iinfo(data.dtype)
        scale = max(abs(info.min), info.max)
        normalized = data.astype(np.float32) / float(scale)

    if normalized.ndim > 1:
        normalized = normalized.mean(axis=1)
    return normalized


def load_audio(audio_path: str) -> np.ndarray:
    """Carrega WAV 16kHz Int16 e retorna float32 normalizado."""
    sample_rate, data = wavfile.read(audio_path)
    if sample_rate != SAMPLE_RATE:
        raise ValueError(f"{audio_path} deve estar em {SAMPLE_RATE}Hz, veio {sample_rate}Hz")
    return normalize_audio(data)


def chunk_has_speech(audio_chunk: np.ndarray, threshold: float = 0.01) -> bool:
    """Filtro barato para não transcrever silêncio residual dentro das ilhas de VAD."""
    if audio_chunk.size == 0:
        return False
    samples = np.asarray(audio_chunk, dtype=np.float64)
    rms = float(np.sqrt(np.mean(samples * samples)))
    return rms >= threshold


def load_and_denoise(audio_path: str, prop_decrease: float = 0.75) -> np.ndarray:
    """Carrega WAV 16kHz Int16, aplica noisereduce e retorna float32.
    Usar apenas para ruído estacionário de fundo (ventilador, ar-condicionado).
    NÃO usar para remover fala/bleed de outra trilha — degrada o mic.
    """
    audio = load_audio(audio_path)
    return nr.reduce_noise(
        y=audio, sr=SAMPLE_RATE,
        stationary=True,
        prop_decrease=prop_decrease,
        n_fft=512,        # janela menor (32ms) → preserva melhor consoantes PT-BR
        win_length=512,
        hop_length=128,
    )


def detect_speech_islands(audio: np.ndarray) -> list[dict]:
    """Detecta ilhas de fala no áudio original usando o Silero VAD do faster-whisper."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    return get_speech_timestamps(
        audio,
        VadOptions(**CHUNK_VAD_PARAMETERS),
        sampling_rate=SAMPLE_RATE,
    )


def group_speech_islands(islands: list[dict]) -> list[dict]:
    """Agrupa ilhas próximas em janelas curtas para preservar contexto local.

    Marca com overlap=True chunks que começam por corte artificial de span
    (fala contínua dividida pelo limite de 28s) — esses recebem overlap de
    áudio do chunk anterior na transcrição. Chunks separados por silêncio
    real (gap > CHUNK_MAX_GAP_SEC) não precisam de overlap.
    """
    if not islands:
        return []

    max_gap_samples = int(CHUNK_MAX_GAP_SEC * SAMPLE_RATE)
    max_span_samples = int(CHUNK_MAX_SPAN_SEC * SAMPLE_RATE)

    grouped = [{**islands[0], "overlap": False}]
    for island in islands[1:]:
        current = grouped[-1]
        gap = island["start"] - current["end"]
        span_if_merged = island["end"] - current["start"]
        if gap <= max_gap_samples and span_if_merged <= max_span_samples:
            current["end"] = island["end"]
        else:
            grouped.append({**island, "overlap": gap <= max_gap_samples})
    return grouped


def drop_overlap_duplicates(
    segments: list[Segment],
    covered_until_sec: float,
    tolerance_sec: float = CHUNK_DEDUP_TOLERANCE_SEC,
) -> list[Segment]:
    """Dedup na costura: descarta segmentos TOTALMENTE dentro da janela já
    transcrita pelo chunk anterior (o overlap reapresenta esses segundos).

    Segmento que começa na janela coberta mas termina além dela contém conteúdo
    novo e é mantido — descartá-lo perderia fala real (um único segmento longo
    pode cobrir o chunk inteiro). O custo é uma pequena repetição de texto na
    costura, preferível à perda de conteúdo.
    """
    return [
        seg for seg in segments
        if not (
            seg.start < covered_until_sec
            and seg.end <= covered_until_sec + tolerance_sec
        )
    ]


def _speaker_label(index: int) -> str:
    return f"Remote_{chr(ord('A') + index)}"


def relabel_system_speakers(
    segments: list[Segment],
    system_audio: np.ndarray,
    sys_offset_sec: float,
    max_speakers: int = 8,
) -> None:
    """Rotula remotos como Remote_A/B/... usando GE2E embeddings (resemblyzer).

    Falls back to lightweight RMS/ZCR/pitch heuristics if resemblyzer is not available.
    """
    try:
        _relabel_resemblyzer(segments, system_audio, sys_offset_sec, max_speakers)
    except ImportError:
        print("  [diarize] resemblyzer not available — using RMS/pitch heuristics", flush=True)
        _relabel_heuristic(segments, system_audio, sys_offset_sec)
    except Exception as exc:
        print(
            f"  [diarize] resemblyzer failed ({type(exc).__name__}) — using RMS/pitch heuristics",
            flush=True,
        )
        _relabel_heuristic(segments, system_audio, sys_offset_sec)


def _relabel_resemblyzer(
    segments: list[Segment],
    system_audio: np.ndarray,
    sys_offset_sec: float,
    max_speakers: int,
) -> None:
    """GE2E embeddings + agglomerative clustering (cosine, average linkage)."""
    from resemblyzer import VoiceEncoder, preprocess_wav
    from sklearn.cluster import AgglomerativeClustering
    from sklearn.metrics import silhouette_score

    system_segs = [seg for seg in segments if seg.speaker == "Interlocutor"]
    if not system_segs:
        return

    encoder = VoiceEncoder("cpu")
    min_chunk_samples = int(SAMPLE_RATE * 0.4)
    embeddings: list[np.ndarray] = []

    for seg in system_segs:
        start = max(0, int((seg.start - sys_offset_sec) * SAMPLE_RATE))
        end = min(len(system_audio), int((seg.end - sys_offset_sec) * SAMPLE_RATE))
        chunk = system_audio[start:end]
        if len(chunk) < min_chunk_samples:
            embeddings.append(np.zeros(encoder.embedding_size, dtype=np.float32))
        else:
            wav = preprocess_wav(chunk.astype(np.float64), source_sr=SAMPLE_RATE)
            embeddings.append(encoder.embed_utterance(wav))

    X = np.array(embeddings, dtype=np.float32)
    n = len(system_segs)

    if n < 4:
        for seg in system_segs:
            seg.speaker = _speaker_label(0)
        return

    # A split needs repeated evidence for each label. In particular, do not
    # force two clusters just because multiple segments exist.
    best_k: int | None = None
    best_score = -1.0
    upper_k = min(max_speakers, n // 2, 8)
    for k in range(2, upper_k + 1):
        labels = AgglomerativeClustering(
            n_clusters=k, metric="cosine", linkage="average"
        ).fit_predict(X)
        _, counts = np.unique(labels, return_counts=True)
        if len(counts) < 2 or np.any(counts < 2):
            continue
        score = float(silhouette_score(X, labels, metric="cosine"))
        if score >= 0.25 and score > best_score:
            best_score = score
            best_k = k

    if best_k is None:
        for seg in system_segs:
            seg.speaker = _speaker_label(0)
        print("  [diarize] insufficient evidence for multiple remote speakers", flush=True)
        return

    labels = AgglomerativeClustering(
        n_clusters=best_k, metric="cosine", linkage="average"
    ).fit_predict(X)

    label_map: dict[int, str] = {}
    for i, seg in enumerate(system_segs):
        lbl = int(labels[i])
        if lbl not in label_map:
            label_map[lbl] = _speaker_label(len(label_map))
        seg.speaker = label_map[lbl]

    print(
        f"  [diarize] {best_k} remote speaker(s) detected "
        f"(resemblyzer GE2E, silhouette={best_score:.2f})",
        flush=True,
    )


def _relabel_heuristic(
    segments: list[Segment],
    system_audio: np.ndarray,
    sys_offset_sec: float,
) -> None:
    """Fallback: lightweight RMS + ZCR + pitch greedy centroid clustering."""
    clusters: list[SpeakerCluster] = []
    for segment in sorted(
        (seg for seg in segments if seg.speaker == "Interlocutor"),
        key=lambda item: item.start,
    ):
        start_sample = max(0, int(round((segment.start - sys_offset_sec) * SAMPLE_RATE)))
        end_sample = min(
            len(system_audio),
            int(round((segment.end - sys_offset_sec) * SAMPLE_RATE)),
        )
        if end_sample <= start_sample:
            continue
        chunk = system_audio[start_sample:end_sample]
        samples = np.asarray(chunk, dtype=np.float64)
        rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
        rms_db = 20.0 * math.log10(max(rms, 1e-6))
        signs = np.signbit(samples)
        zcr = float(np.mean(signs[1:] != signs[:-1])) if samples.size > 1 else 0.0
        features = (rms_db, zcr, 0.0)  # pitch dropped — unreliable for short turns

        if not clusters:
            clusters.append(SpeakerCluster(label=_speaker_label(0), centroid=features))
            segment.speaker = clusters[-1].label
            continue

        dists = [
            abs(features[0] - c.centroid[0]) / 12.0 + abs(features[1] - c.centroid[1]) / 0.08
            for c in clusters
        ]
        best = int(np.argmin(dists))
        if dists[best] > 1.4 and len(clusters) < 6:
            clusters.append(SpeakerCluster(label=_speaker_label(len(clusters)), centroid=features))
            segment.speaker = clusters[-1].label
        else:
            c = clusters[best]
            n = c.count + 1
            c.centroid = tuple((old * c.count + new) / n for old, new in zip(c.centroid, features))  # type: ignore[assignment]
            c.count = n
            segment.speaker = c.label


def trim_prompt_tail(text: str, max_chars: int = PROMPT_TAIL_MAX_CHARS) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= max_chars:
        return text
    tail = text[-max_chars:].strip()
    if " " in tail:
        tail = tail.split(" ", 1)[1].strip()
    return tail


def build_prompt_tail(segments: list[Segment], max_chars: int = PROMPT_TAIL_MAX_CHARS) -> str | None:
    useful_parts = [
        seg.text
        for seg in segments
        if seg.text and not segment_is_suspect(seg) and "[inaudível]" not in seg.text
    ]
    if not useful_parts:
        return None
    return trim_prompt_tail(" ".join(useful_parts), max_chars=max_chars)


def build_contextual_initial_prompt(
    config: TranscriptionConfig,
    prompt_tail: str | None = None,
) -> str | None:
    prompt = build_initial_prompt(config)
    if prompt_tail:
        context = f"Contexto anterior recente: {prompt_tail}"
        prompt = f"{prompt} {context}".strip() if prompt else context
    return prompt


def transcription_kwargs(
    config: TranscriptionConfig,
    vad_filter: bool,
    prompt_tail: str | None = None,
) -> dict:
    lang_cfg = get_lang_config(config.language)
    kwargs = dict(
        language=lang_cfg["whisper_lang"],
        initial_prompt=build_contextual_initial_prompt(config, prompt_tail),
        vad_filter=vad_filter,
        no_speech_threshold=0.6,
        log_prob_threshold=-0.8,
        condition_on_previous_text=True,   # contexto dentro do chunk; não persiste entre chunks
        beam_size=5,
        word_timestamps=True,
        hallucination_silence_threshold=2.0,
        hotwords=build_hotwords(config),
    )
    if vad_filter:
        kwargs["vad_parameters"] = VAD_PARAMETERS
    return kwargs


# ---------------------------------------------------------------------------
# MLX backend — Apple Metal via mlx-whisper (Apple Silicon only)
# ---------------------------------------------------------------------------

class MlxBackend:
    """Wraps mlx_whisper.transcribe with the same interface as WhisperModel.

    Accepts faster-whisper-style kwargs and converts internally so
    transcribe_track needs no changes.
    """

    def __init__(self, model_repo: str) -> None:
        self.model_repo = model_repo

    def _resolve_model_path(self) -> str:
        """Return local snapshot dir if cached, else HF repo id (triggers download)."""
        try:
            from huggingface_hub import snapshot_download
            return snapshot_download(self.model_repo, local_files_only=True)
        except Exception:
            return self.model_repo

    def transcribe(self, audio_input, **kwargs):
        try:
            import mlx_whisper
        except ImportError:
            raise RuntimeError(
                "mlx-whisper not installed. Run: pip install mlx-whisper"
            )

        # mlx-whisper has no native hotwords — fold into initial_prompt
        initial_prompt = kwargs.get("initial_prompt") or ""
        hotwords = kwargs.get("hotwords")
        if hotwords:
            initial_prompt = f"{initial_prompt} {hotwords}".strip()

        mlx_kwargs = dict(
            path_or_hf_repo=self._resolve_model_path(),
            language=kwargs.get("language"),
            initial_prompt=initial_prompt or None,
            no_speech_threshold=kwargs.get("no_speech_threshold", 0.6),
            logprob_threshold=kwargs.get("log_prob_threshold", -0.8),
            condition_on_previous_text=kwargs.get("condition_on_previous_text", True),
            word_timestamps=kwargs.get("word_timestamps", False),
            hallucination_silence_threshold=kwargs.get("hallucination_silence_threshold"),
            verbose=None,  # None disables tqdm bar; False paradoxically enables it
        )
        # beam_size not supported by mlx-whisper (greedy only) — dropped
        # vad_filter / vad_parameters are handled externally — dropped
        _warned = getattr(self, "_greedy_warned", False)
        if not _warned:
            print(
                "  [MLX] greedy decoding only (beam_size=1); "
                "VAD handled externally. Use --backend faster-whisper for beam search.",
                flush=True,
            )
            self._greedy_warned = True

        result = mlx_whisper.transcribe(audio_input, **mlx_kwargs)

        # Normalize dict segments to attribute-access objects (same as faster-whisper)
        segments = [
            SimpleNamespace(
                start=seg["start"],
                end=seg["end"],
                text=seg["text"],
                words=seg.get("words", []),
                avg_logprob=seg.get("avg_logprob"),
                no_speech_prob=seg.get("no_speech_prob"),
            )
            for seg in result.get("segments", [])
        ]

        duration = (
            len(audio_input) / SAMPLE_RATE
            if isinstance(audio_input, np.ndarray)
            else (segments[-1].end if segments else 0.0)
        )
        info = SimpleNamespace(
            duration=duration,
            language=result.get("language", kwargs.get("language", "pt")),
            language_probability=1.0,
        )
        return segments, info


def collect_segments(
    raw_segments,
    speaker: str,
    base_offset_sec: float,
    config: TranscriptionConfig,
) -> list[Segment]:
    segments = []
    for seg in raw_segments:
        raw_text = seg.text.strip()
        # Normalize whitespace including verse-like \n that Whisper emits on rhythmic pauses
        raw_text = re.sub(r"\s+", " ", raw_text)
        text = raw_text
        text = apply_text_replacements(text, config.replacements)
        text, text_is_suspect = sanitize_intraword_runaways(text)
        text = collapse_runaway_repetitions(text)
        text = normalize_laughter(text)
        text = normalize_known_names(text, config.known_names)
        if not text or text in (".", ",", "...", "…"):
            continue
        segments.append(Segment(
            start=seg.start + base_offset_sec,
            end=seg.end + base_offset_sec,
            text=text,
            speaker=speaker,
            avg_logprob=getattr(seg, "avg_logprob", None),
            no_speech_prob=getattr(seg, "no_speech_prob", None),
            raw_text=raw_text,
            text_is_suspect=text_is_suspect,
        ))
    return segments


# ---------------------------------------------------------------------------
# Transcription — modelo carregado UMA vez, reutilizado nas duas trilhas
# ---------------------------------------------------------------------------

def transcribe_track(
    audio_path: str,
    speaker: str,
    model,                          # WhisperModel já instanciado
    config: TranscriptionConfig | None = None,
    offset_sec: float = 0.0,
    denoise: bool = False,
    chunk_by_silence: bool = True,
    chunk_overlap: bool = True,
    profile_memory: bool = False,
    progress_base_sec: float = 0.0,
    total_sec: float = 1.0,
) -> list[Segment]:
    config = config or TranscriptionConfig()

    flags = []
    if denoise:
        flags.append("denoised")
    if chunk_by_silence:
        flags.append("speech-islands")
    if config.language == "auto":
        flags.append("auto-lang")
    label = f"'{speaker}'" if speaker else "single-track"
    flag_str = f" ({', '.join(flags)})" if flags else ""
    print(f"  Transcribing {Path(audio_path).name} as {label}{flag_str}...", flush=True)

    if denoise:
        audio_input = load_and_denoise(audio_path)
    else:
        audio_input = audio_path     # passa path direto — evita roundtrip desnecessário

    if not chunk_by_silence:
        raw_segments, info = model.transcribe(
            audio_input,
            **transcription_kwargs(config, vad_filter=True),
        )

        if config.language == "auto":
            print(f"    Detected: {info.language} ({info.language_probability:.0%})", flush=True)

        segments = collect_segments(raw_segments, speaker, offset_sec, config)
        emit_progress(90 * (progress_base_sec + info.duration) / total_sec)
        print(f"    {len(segments)} segments, {round(info.duration, 1)}s audio", flush=True)
        return segments

    _mem("load-audio-before", profile_memory)
    audio = audio_input if isinstance(audio_input, np.ndarray) else load_audio(audio_path)
    _mem("load-audio-after", profile_memory)
    islands = detect_speech_islands(audio)
    _mem("detect-islands-after", profile_memory)
    if not islands:
        print(f"    0 speech islands, {round(len(audio) / SAMPLE_RATE, 1)}s audio", flush=True)
        return []

    chunks = group_speech_islands(islands)
    segments = []
    detected_languages = []
    overlap_samples = int(CHUNK_OVERLAP_SEC * SAMPLE_RATE)
    covered_until_sec: float | None = None   # fim (em s da trilha) do último chunk transcrito
    for i, chunk_info in enumerate(chunks, start=1):
        start_sample = chunk_info["start"]
        end_sample = chunk_info["end"]
        use_overlap = chunk_overlap and chunk_info.get("overlap", False)
        slice_start = max(0, start_sample - overlap_samples) if use_overlap else start_sample
        chunk = audio[slice_start:end_sample]
        chunk_offset_sec = offset_sec + (slice_start / SAMPLE_RATE)

        if not chunk_has_speech(chunk):
            print(
                f"    chunk {i}/{len(chunks)}: "
                f"{format_time(start_sample / SAMPLE_RATE)}–{format_time(end_sample / SAMPLE_RATE)} "
                "(silence skipped)",
                flush=True,
            )
            continue

        prompt_tail = build_prompt_tail(segments)
        raw_segments, info = model.transcribe(
            chunk,
            **transcription_kwargs(config, vad_filter=False, prompt_tail=prompt_tail),
        )
        if config.language == "auto":
            detected_languages.append((info.language, info.language_probability))
        chunk_segments = collect_segments(raw_segments, speaker, chunk_offset_sec, config)
        if use_overlap and covered_until_sec is not None:
            before = len(chunk_segments)
            chunk_segments = drop_overlap_duplicates(
                chunk_segments, offset_sec + covered_until_sec
            )
            dropped = before - len(chunk_segments)
        else:
            dropped = 0
        segments.extend(chunk_segments)
        covered_until_sec = end_sample / SAMPLE_RATE
        emit_progress(90 * (progress_base_sec + covered_until_sec) / total_sec)
        if profile_memory and i % 10 == 0:
            _mem(f"chunk-{i}/{len(chunks)}", profile_memory)

        overlap_note = ""
        if use_overlap:
            overlap_note = f" (+{CHUNK_OVERLAP_SEC:.0f}s overlap"
            overlap_note += f", {dropped} dup dropped)" if dropped else ")"
        print(
            f"    chunk {i}/{len(chunks)}: "
            f"{format_time(start_sample / SAMPLE_RATE)}–{format_time(end_sample / SAMPLE_RATE)}"
            f"{overlap_note}",
            flush=True,
        )

    if detected_languages:
        best_lang, best_prob = max(detected_languages, key=lambda item: item[1])
        print(f"    Detected: {best_lang} ({best_prob:.0%} best chunk)", flush=True)

    print(
        f"    {len(segments)} segments, {len(chunks)} speech chunk(s) "
        f"from {len(islands)} island(s), "
        f"{round(len(audio) / SAMPLE_RATE, 1)}s audio",
        flush=True,
    )
    return segments


# ---------------------------------------------------------------------------
# LLM-oriented output
# ---------------------------------------------------------------------------

def confidence_from_logprob(avg_logprob: float | None) -> float:
    if avg_logprob is None:
        return -1.0
    return round(max(0.0, min(1.0, math.exp(avg_logprob))), 4)


def segment_is_suspect(segment: Segment) -> bool:
    if segment.text_is_suspect:
        return True
    if segment.avg_logprob is not None and segment.avg_logprob < -0.8:
        return True
    if segment.no_speech_prob is not None and segment.no_speech_prob >= 0.6:
        return True
    duration = segment.end - segment.start
    quality_text = segment.raw_text if segment.raw_text is not None else segment.text
    if duration > 0 and len(quality_text) / duration > TEXT_DENSITY_SUSPECT_CHARS_PER_SEC:
        return True
    return False


def segment_has_structural_artifact(segment: Segment) -> bool:
    if segment.no_speech_prob is not None and segment.no_speech_prob >= 0.6:
        return True
    duration = segment.end - segment.start
    quality_text = segment.raw_text if segment.raw_text is not None else segment.text
    if duration > 0 and len(quality_text) / duration > TEXT_DENSITY_SUSPECT_CHARS_PER_SEC:
        return True
    return False


def usable_text_without_markers(text: str) -> str:
    return re.sub(r"\[inaudível\]|\s|[.,!?…:;()\[\]\-]", "", text, flags=re.UNICODE)


def safe_text_for_segment(segment: Segment, is_suspect: bool) -> str:
    """Mantém texto incerto quando ainda é útil; oculta só artefatos fortes."""
    if not is_suspect:
        return segment.text
    if segment.text_is_suspect:
        text = compact_inaudible_markers(segment.text)
        if "[inaudível]" in text and usable_text_without_markers(text):
            return text
        return "[inaudível]"
    if segment_has_structural_artifact(segment):
        return "[inaudível]"
    return segment.text


def compact_inaudible_markers(text: str) -> str:
    return re.sub(r"(?:\[inaudível\]\s*){2,}", "[inaudível] ", text).strip()


def join_text_parts(parts: list[str]) -> str:
    return compact_inaudible_markers(" ".join(part.strip() for part in parts if part.strip()))


def split_text_evenly(text: str, parts_count: int, filler: str = "[inaudível]") -> list[str]:
    words = text.split()
    if parts_count <= 1:
        return [text.strip()] if text.strip() else []
    if not words:
        return [filler] * parts_count
    if len(words) < parts_count:
        return [*words, *([filler] * (parts_count - len(words)))]

    target_chars = max(1, math.ceil(len(text) / parts_count))
    parts: list[str] = []
    current: list[str] = []
    current_len = 0

    for word in words:
        projected_len = current_len + len(word) + (1 if current else 0)
        if current and projected_len > target_chars and len(parts) < parts_count - 1:
            parts.append(" ".join(current))
            current = [word]
            current_len = len(word)
        else:
            current.append(word)
            current_len = projected_len

    if current:
        parts.append(" ".join(current))
    return parts


def split_long_segment(segment: Segment, max_duration_s: float) -> list[Segment]:
    duration = segment.end - segment.start
    if max_duration_s <= 0 or duration <= max_duration_s:
        return [segment]

    parts_count = max(1, math.ceil(duration / max_duration_s))
    text_parts = split_text_evenly(segment.text, parts_count) or [segment.text]
    raw_parts = (
        split_text_evenly(segment.raw_text, len(text_parts))
        if segment.raw_text is not None else [None] * len(text_parts)
    )
    part_duration = duration / len(text_parts)

    split_segments: list[Segment] = []
    for index, text_part in enumerate(text_parts):
        start = segment.start + (index * part_duration)
        end = segment.end if index == len(text_parts) - 1 else start + part_duration
        split_segments.append(Segment(
            start=start,
            end=end,
            text=text_part,
            speaker=segment.speaker,
            avg_logprob=segment.avg_logprob,
            no_speech_prob=segment.no_speech_prob,
            raw_text=raw_parts[index] if index < len(raw_parts) else None,
            text_is_suspect=segment.text_is_suspect or text_part == "[inaudível]",
        ))
    return split_segments


def turn_from_segments(segments: list[Segment]) -> Turn:
    avg_logprobs = [seg.avg_logprob for seg in segments if seg.avg_logprob is not None]
    avg_logprob = sum(avg_logprobs) / len(avg_logprobs) if avg_logprobs else None
    confidence = confidence_from_logprob(avg_logprob)
    segment_suspicions = [segment_is_suspect(seg) for seg in segments]
    text = join_text_parts([seg.text for seg in segments])
    raw_text = join_text_parts([seg.raw_text or seg.text for seg in segments])
    safe_text = join_text_parts([
        safe_text_for_segment(seg, is_suspect)
        for seg, is_suspect in zip(segments, segment_suspicions)
    ])
    is_suspect = any(segment_suspicions) or (confidence != -1.0 and confidence < 0.6)
    return Turn(
        speaker=segments[0].speaker or "Áudio",
        text=text,
        start_ms=int(round(min(seg.start for seg in segments) * 1000)),
        end_ms=int(round(max(seg.end for seg in segments) * 1000)),
        confidence=confidence,
        is_suspect=is_suspect,
        raw_text=raw_text if raw_text != text else None,
        safe_text=safe_text if safe_text != text else None,
        track=infer_track_from_speaker(segments[0].speaker or "Áudio"),
    )


def consolidate_turns(
    segments: list[Segment],
    gap_threshold_s: float = 2.0,
    max_turn_duration_s: float = 30.0,
) -> list[Turn]:
    """Agrupa segmentos próximos do mesmo speaker e ordena os turnos por início.

    max_turn_duration_s caps how long a single turn can grow, preventing monster
    turns when multiple remote speakers talk back-to-back without a gap.
    """
    expanded_segments = [
        split_segment
        for segment in segments
        for split_segment in split_long_segment(segment, max_turn_duration_s)
    ]

    grouped: list[list[Segment]] = []
    for seg in sorted(expanded_segments, key=lambda item: (item.start, item.end, item.speaker)):
        speaker = seg.speaker or "Áudio"
        if grouped and (grouped[-1][-1].speaker or "Áudio") == speaker:
            last_group = grouped[-1]
            gap = seg.start - last_group[-1].end
            span_if_added = seg.end - last_group[0].start
            if gap < gap_threshold_s and span_if_added <= max_turn_duration_s:
                last_group.append(seg)
                continue
        grouped.append([seg])

    turns = [
        turn_from_segments(group)
        for group in grouped
    ]
    return sorted(turns, key=lambda turn: (turn.start_ms, turn.end_ms, turn.speaker))


def build_meeting_meta(
    title: str,
    language: str,
    turns: list[Turn],
    tracks: str,
    backend: str,
    model_name: str,
    analysis_context: dict[str, str] | None = None,
    participants: list[str] | None = None,
    analysis_goal: str | None = None,
    session_id: str | None = None,
    capture_integrity: str = "unknown",
    capture_issues: list[str] | None = None,
    recorded_at: str | None = None,
) -> dict:
    processed_at = datetime.now().astimezone().isoformat(timespec="seconds")
    meta = {
        "title": title,
        "date": recorded_at or processed_at,
        "processed_at": processed_at,
        "duration_ms": max((turn.end_ms for turn in turns), default=0),
        "language": language,
        "tracks": tracks,
        "speakers": sorted({turn.speaker for turn in turns}),
        "backend": backend,
        "model": model_name,
        "pipeline_version": PIPELINE_VERSION,
        "capture_integrity": capture_integrity,
    }
    if session_id:
        meta["session_id"] = session_id
    if capture_issues:
        meta["capture_issues"] = capture_issues
    if analysis_goal:
        meta["analysis_goal"] = analysis_goal
    if participants:
        meta["participants_expected"] = participants
    if analysis_context:
        meta["context"] = analysis_context
    return meta


def apply_speaker_map(turns: list[Turn], speaker_map: dict[str, str]) -> None:
    for turn in turns:
        turn.speaker = speaker_map.get(turn.speaker, turn.speaker)


def infer_track_from_speaker(speaker: str) -> str:
    if speaker == "Você":
        return "mic"
    if speaker == "Interlocutor" or speaker.startswith("Remote_"):
        return "system"
    return "unknown"


def quality_flags_for_turn(turn: Turn, text: str, raw_text: str, safe_text: str) -> list[str]:
    flags: list[str] = []
    if turn.is_suspect:
        flags.append("suspect")
    if turn.confidence != -1.0 and turn.confidence < 0.6:
        flags.append("low_confidence")
    if "[inaudível]" in safe_text:
        flags.append("inaudible")
    if raw_text != text:
        flags.append("raw_differs")
    if safe_text != text:
        flags.append("sanitized")
    if turn.speaker == "Interlocutor":
        flags.append("remote_unclustered")
    if turn.speaker.startswith("Remote_"):
        flags.append("remote_clustered")
    if turn.track == "system" and turn.speaker != "Interlocutor" and not turn.speaker.startswith("Remote_"):
        flags.append("remote_named")
    return flags


def build_analysis_jsonl(
    turns: list[Turn],
    meta: dict | None = None,
) -> str:
    """JSONL rico para análise de persona, voz, posicionamento e contexto social."""
    lines = []
    if meta is not None:
        analysis_meta = {"type": "meta", "purpose": "persona_analysis", **meta}
        lines.append(json.dumps(analysis_meta, ensure_ascii=False, separators=(",", ":")))

    max_previous_end = 0
    for turn in turns:
        text = turn.text
        raw_text = turn.raw_text or turn.text
        safe_text = turn_output_text(turn, sanitize_suspect=True)
        overlap_ms = max(0, max_previous_end - turn.start_ms)
        max_previous_end = max(max_previous_end, turn.end_ms)

        record = {
            "type": "turn",
            "speaker": turn.speaker,
            "track": turn.track or infer_track_from_speaker(turn.speaker),
            "text": text,
            "raw_text": raw_text,
            "safe_text": safe_text,
            "start_ms": turn.start_ms,
            "end_ms": turn.end_ms,
            "duration_ms": max(0, turn.end_ms - turn.start_ms),
            "overlap_ms": overlap_ms,
            "confidence": turn.confidence,
            "is_suspect": turn.is_suspect,
            "quality_flags": quality_flags_for_turn(turn, text, raw_text, safe_text),
        }
        lines.append(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    return "\n".join(lines) + ("\n" if lines else "")


def build_jsonl(
    turns: list[Turn],
    filter_suspect: bool = False,
    sanitize_suspect: bool = True,
    meta: dict | None = None,
) -> str:
    lines = []
    if meta is not None:
        lines.append(json.dumps(
            {"type": "meta", **meta}, ensure_ascii=False, separators=(",", ":"),
        ))
    for turn in turns:
        if filter_suspect and turn.is_suspect:
            continue
        text = turn_output_text(turn, sanitize_suspect=sanitize_suspect)

        record: dict = {"type": "turn"} if meta is not None else {}
        record.update({
            "speaker": turn.speaker,
            "text": text,
            "start_ms": turn.start_ms,
            "end_ms": turn.end_ms,
            "confidence": turn.confidence,
            "is_suspect": turn.is_suspect,
        })
        source_text = turn.raw_text or turn.text
        if source_text != text:
            record["raw_text"] = source_text
        lines.append(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    return "\n".join(lines) + ("\n" if lines else "")


def write_text_atomic(path: Path, content: str) -> None:
    """Publica um artefato completo por rename no mesmo diretório."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".inprogress",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def turn_output_text(turn: Turn, sanitize_suspect: bool = True) -> str:
    if not sanitize_suspect and turn.raw_text:
        return turn.raw_text
    if sanitize_suspect and turn.is_suspect and turn.safe_text:
        return turn.safe_text
    return turn.text


def build_llm_package(meta: dict, jsonl_text: str) -> str:
    """Artefato único auto-contido para colar/ingerir numa LLM."""
    speakers = ", ".join(meta["speakers"]) if meta["speakers"] else "—"
    lines = [
        f"# Transcrição de reunião: {meta['title']}",
        "",
        f"- **Data:** {meta['date']}",
        f"- **Duração:** {format_time(meta['duration_ms'] / 1000.0)}",
        f"- **Participantes (labels):** {speakers}",
        f"- **Idioma:** {meta['language']}",
        "",
        "## Contexto para o assistente",
        "",
        "O bloco abaixo é a transcrição integral de uma reunião, em JSONL — uma linha "
        "por turno de fala, ordenada por tempo. Campos: `speaker` (rótulo do falante; "
        "`Você` = autor da gravação, `Interlocutor`/`Remote_*` = participantes remotos), "
        "`text`, `start_ms`/`end_ms`, `confidence` (0-1; -1 = indisponível) e "
        "`is_suspect` (trecho de baixa confiança). `[inaudível]` marca áudio não "
        "recuperado; `[risos]` marca riso. Use esta transcrição como contexto fiel da "
        "reunião ao responder.",
        "",
        "## Transcrição (JSONL)",
        "",
        "```jsonl",
        jsonl_text.rstrip("\n"),
        "```",
        "",
    ]
    return "\n".join(lines)


def build_markdown(
    title: str,
    turns: list[Turn],
    dual_track: bool,
    language: str,
    sanitize_suspect: bool = True,
    capture_integrity: str = "unknown",
    capture_issues: list[str] | None = None,
    recorded_at: str | None = None,
) -> str:
    now = datetime.now()
    duration = max((turn.end_ms for turn in turns), default=0) / 1000.0
    lang_label = {"pt": "PT-BR", "en": "EN", "auto": "auto-detect"}.get(language, language)

    lines = [
        f"# {title}", "",
        f"**Data:** {recorded_at or now.strftime('%Y-%m-%d %H:%M')}",
        f"**Duração:** {format_time(duration)}",
        f"**Trilhas:** {'mic + sistema' if dual_track else 'única'}",
        f"**Idioma:** {lang_label}",
        "", "---", "",
    ]
    if capture_integrity == "degraded":
        lines.extend([
            "> ⚠ Captura parcial. O conteúdo abaixo pode estar incompleto.",
            *[f"> - {issue}" for issue in (capture_issues or [])],
            "",
        ])
    for turn in turns:
        ts = format_time(turn.start_ms / 1000.0)
        suspect = " ⚠ suspeito" if turn.is_suspect else ""
        text = turn_output_text(turn, sanitize_suspect=sanitize_suspect)
        lines.append(
            f"**{turn.speaker}:** [{ts}] {text}{suspect}"
            if dual_track else f"[{ts}] {text}{suspect}"
        )
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def slugify(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    text = re.sub(r"[\s_]+", "-", text)
    return text.strip("-")[:60]


def format_time(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}"


def validate_audio_inputs(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    import wave

    for role, audio_path in (("microfone", args.mic), ("sistema", args.system)):
        if not audio_path:
            continue

        path = Path(audio_path)
        if not path.is_file():
            parser.error(f"Arquivo de áudio do {role} não encontrado: {path}")
        if path.stat().st_size <= 44:
            parser.error(f"Arquivo de áudio do {role} está vazio: {path}")

        try:
            with wave.open(str(path), "rb") as wav:
                frames = wav.getnframes()
                sample_rate = wav.getframerate()
                data_bytes = frames * wav.getsampwidth() * wav.getnchannels()
        except (wave.Error, EOFError) as exc:
            parser.error(
                f"Arquivo de áudio do {role} está corrompido ou truncado: {path} ({exc})"
            )
            return  # parser.error levanta SystemExit; return acalma o type checker
        if frames <= 0:
            parser.error(f"Arquivo de áudio do {role} não contém amostras: {path}")
        if path.stat().st_size < data_bytes:
            parser.error(
                f"Arquivo de áudio do {role} está corrompido ou truncado "
                f"(esperava {data_bytes} bytes de áudio): {path}"
            )
        if sample_rate != SAMPLE_RATE:
            parser.error(
                f"Arquivo de áudio do {role} deve estar em {SAMPLE_RATE}Hz, "
                f"veio {sample_rate}Hz: {path}"
            )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcreve reunião (mic + sistema) → JSONL para LLM e Markdown compatível"
    )
    parser.add_argument("--mic", help="Caminho para arquivo de áudio do microfone")
    parser.add_argument("--system", help="Caminho para arquivo de áudio do sistema")
    parser.add_argument("--out", required=True, help="Diretório de saída")
    parser.add_argument("--title", default="Reunião", help="Título da reunião")
    parser.add_argument(
        "--format", default="both", choices=["jsonl", "markdown", "both", "llm", "analysis"],
        help=(
            "Formato de saída: jsonl, markdown, both (default), llm "
            "(arquivo .md único auto-contido) ou analysis (JSONL rico para análise)"
        ),
    )
    parser.add_argument(
        "--persona-analysis", action="store_true",
        help=(
            "Atalho para análise de persona/voz/contexto: gera --format analysis, "
            "ativa clusterização remota quando possível e usa turnos mais curtos"
        ),
    )
    parser.add_argument(
        "--language", default="pt", choices=["pt", "en", "auto"],
        help="Idioma: pt (PT-BR, default), en (inglês), auto (detecção automática)",
    )
    parser.add_argument("--session-id", help="ID estável da sessão para proveniência e saída única")
    parser.add_argument("--recorded-at", help="Data/hora ISO-8601 do início da gravação")
    parser.add_argument(
        "--capture-integrity", default="unknown", choices=["unknown", "complete", "degraded"],
        help="Integridade observada da captura antes da transcrição",
    )
    parser.add_argument(
        "--capture-issue", action="append", default=[],
        help="Limitação observada da captura (pode repetir)",
    )
    parser.add_argument(
        "--backend", default="mlx", choices=["mlx", "faster-whisper"],
        help="Backend de inferência: mlx (default, Apple Metal) ou faster-whisper (CPU)",
    )
    parser.add_argument(
        "--mlx-model",
        default="mlx-community/whisper-large-v3-mlx",
        help="Repositório HuggingFace do modelo MLX (usado com --backend mlx)",
    )
    parser.add_argument(
        "--model", default="medium",
        choices=["tiny", "base", "small", "medium", "large-v2", "large-v3"],
        help="Modelo Whisper para backend faster-whisper (ignorado com --backend mlx)",
    )
    parser.add_argument(
        "--sys-offset", type=float, default=0.0, metavar="MS",
        help="Offset do sistema em ms (positivo = sistema iniciou depois do mic)",
    )
    # --mic-offset mantido para compatibilidade retroativa
    parser.add_argument(
        "--mic-offset", type=float, default=0.0, metavar="MS",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--denoise", action="store_true",
        help="Aplica noisereduce no mic (útil para ruído estacionário, NÃO para bleed de fala)",
    )
    parser.add_argument(
        "--trim-after-mic", action="store_true",
        help="Descarta segmentos do sistema após o último segmento do mic",
    )
    parser.add_argument(
        "--cluster-system-speakers", action="store_true",
        help="Rotula a trilha do sistema como Remote_A/B/... usando heurísticas locais de áudio",
    )
    parser.add_argument(
        "--config-json",
        help=(
            "Arquivo JSON opcional com context_terms e replacements. "
            "Ex: {\"context_terms\": [\"Markdown\"], \"replacements\": {\"Crisp\": \"Krisp\"}}"
        ),
    )
    parser.add_argument(
        "--context-term", action="append", default=[],
        help="Termo esperado para enviar como hotword, sem entrar no prompt inicial (pode repetir)",
    )
    parser.add_argument(
        "--replace", action="append", type=parse_replacement, default=[],
        metavar="ORIGEM=DESTINO",
        help="Correção determinística aplicada ao texto transcrito (pode repetir)",
    )
    parser.add_argument(
        "--no-default-replacements", action="store_true",
        help="Desliga correções determinísticas padrão para termos técnicos PT-BR",
    )
    parser.add_argument(
        "--hotword", action="append", default=[],
        help="Nome próprio ou termo técnico a reforçar no Whisper (pode repetir; ex: --hotword 'Azure DevOps')",
    )
    parser.add_argument(
        "--name", action="append", default=[], dest="known_names",
        metavar="NAME",
        help=(
            "Nome próprio de participante para correção fuzzy pós-ASR (pode repetir). "
            "Tokens com ≥75%% de similaridade são corrigidos. Ex: --name Alex --name Jordan"
        ),
    )
    parser.add_argument(
        "--filter-suspect", action="store_true",
        help="Omite turnos marcados como is_suspect do JSONL (entrega stream mais limpo para LLM)",
    )
    parser.add_argument(
        "--no-sanitize", action="store_true",
        help="Mantém texto bruto de turnos suspeitos no JSONL para debug",
    )
    parser.add_argument(
        "--max-turn-duration", "--max-turn", type=float, default=30.0, metavar="SEC",
        help="Duração máxima de um turno consolidado em segundos (default: 30)",
    )
    parser.add_argument(
        "--speaker-map", type=parse_speaker_map, default={},
        metavar="LABEL=NOME[,LABEL=NOME...]",
        help=(
            "Mapeia rótulos de falante para nomes reais no output "
            "(ex: 'Remote_A=Alex,Remote_B=Jordan'). Opt-in: sem a flag, "
            "os rótulos honestos são mantidos"
        ),
    )
    parser.add_argument(
        "--analysis-context", action="append", type=parse_metadata_pair, default=[],
        metavar="CHAVE=VALOR",
        help=(
            "Metadado de contexto para análise de persona (ex: org=ExampleCo, "
            "project=Platform, role=facilitator)"
        ),
    )
    parser.add_argument(
        "--participant", action="append", default=[],
        help="Participante esperado da reunião para metadata de análise (pode repetir)",
    )
    parser.add_argument(
        "--no-meta", action="store_true",
        help="Omite o registro meta da primeira linha do JSONL (formato antigo)",
    )
    parser.add_argument(
        "--no-chunk-overlap", action="store_true",
        help="Desliga o overlap de 3s entre chunks contínuos (comportamento antigo)",
    )
    parser.add_argument(
        "--profile-memory", action="store_true",
        help="Imprime RSS por fase no stderr para diagnóstico de memória (off por default)",
    )
    chunk_group = parser.add_mutually_exclusive_group()
    chunk_group.add_argument(
        "--chunk-by-silence", dest="chunk_by_silence", action="store_true", default=True,
        help="Transcreve por ilhas de fala detectadas por VAD (default)",
    )
    chunk_group.add_argument(
        "--legacy-full-track", dest="chunk_by_silence", action="store_false",
        help="Modo antigo: transcreve a trilha inteira de uma vez",
    )
    args = parser.parse_args()
    _mem("process-start", args.profile_memory)

    if not args.mic and not args.system:
        parser.error("Pelo menos um de --mic ou --system é obrigatório")
    validate_audio_inputs(parser, args)

    if args.persona_analysis:
        args.format = "analysis"
        if args.system and args.mic:
            args.cluster_system_speakers = True
        if args.max_turn_duration == 30.0:
            args.max_turn_duration = 18.0

    config = load_transcription_config(
        language=args.language,
        config_json=args.config_json,
        context_terms=args.context_term,
        replacement_pairs=args.replace,
        hotwords=args.hotword,
        use_default_replacements=not args.no_default_replacements,
    )
    config.known_names.extend(args.known_names)

    mic_duration_sec = audio_duration_sec(args.mic)
    system_duration_sec = audio_duration_sec(args.system)
    total_sec = mic_duration_sec + system_duration_sec or 1.0
    emit_progress(0)

    # Carrega backend de inferência UMA vez — reutilizado nas duas trilhas
    if args.backend == "mlx":
        print(f"  Loading MLX backend: {args.mlx_model}...", flush=True)
        model = MlxBackend(args.mlx_model)
    else:
        from faster_whisper import WhisperModel
        print(f"  Loading Whisper model '{args.model}'...", flush=True)
        model = WhisperModel(args.model, device="auto", compute_type="auto")
    _mem("model-loaded", args.profile_memory)

    segments: list[Segment] = []
    dual_track = bool(args.mic and args.system)
    sys_offset_sec = args.sys_offset / 1000.0

    if args.mic:
        mic_offset_sec = args.mic_offset / 1000.0   # compat retroativa
        speaker = "Você" if dual_track else ""
        segments.extend(transcribe_track(
            args.mic, speaker, model,
            config=config,
            offset_sec=mic_offset_sec,
            denoise=args.denoise,    # OFF por default — bleed de fala não é ruído estacionário
            chunk_by_silence=args.chunk_by_silence,
            chunk_overlap=not args.no_chunk_overlap,
            profile_memory=args.profile_memory,
            progress_base_sec=0,
            total_sec=total_sec,
        ))
        _mem("mic-track-done", args.profile_memory)

    if args.system:
        speaker = "Interlocutor" if dual_track else ""
        segments.extend(transcribe_track(
            args.system, speaker, model,
            config=config,
            offset_sec=sys_offset_sec,
            denoise=False,
            chunk_by_silence=args.chunk_by_silence,
            chunk_overlap=not args.no_chunk_overlap,
            profile_memory=args.profile_memory,
            progress_base_sec=mic_duration_sec,
            total_sec=total_sec,
        ))
        _mem("system-track-done", args.profile_memory)

    if args.cluster_system_speakers and args.system and dual_track:
        _mem("relabel-before", args.profile_memory)
        relabel_system_speakers(segments, load_audio(args.system), sys_offset_sec)
        _mem("relabel-after", args.profile_memory)
    emit_progress(92)

    segments.sort(key=lambda s: s.start)

    if args.trim_after_mic and args.mic and args.system:
        mic_end = max((s.end for s in segments if s.speaker == "Você"), default=None)
        if mic_end is not None:
            before = len(segments)
            segments = [s for s in segments if s.speaker == "Você" or s.start <= mic_end]
            trimmed = before - len(segments)
            if trimmed:
                print(f"  Trimmed {trimmed} system segment(s) after mic end ({format_time(mic_end)})", flush=True)

    turns = consolidate_turns(segments, max_turn_duration_s=args.max_turn_duration)
    emit_progress(95)

    if args.speaker_map:
        apply_speaker_map(turns, args.speaker_map)

    meta = build_meeting_meta(
        title=args.title,
        language=args.language,
        turns=turns,
        tracks="both" if dual_track else ("mic" if args.mic else "system"),
        backend=args.backend,
        model_name=args.mlx_model if args.backend == "mlx" else args.model,
        analysis_context=dict(args.analysis_context),
        participants=args.participant,
        analysis_goal=(
            "Identificar persona, tom, voz, posicionamento, personalidade e contexto"
            if args.persona_analysis or args.format == "analysis" else None
        ),
        session_id=args.session_id,
        capture_integrity=args.capture_integrity,
        capture_issues=args.capture_issue,
        recorded_at=args.recorded_at,
    )

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    now = datetime.now()
    filename_stem = f"{now.strftime('%Y-%m-%d_%H-%M')}_{slugify(args.title)}"
    if args.session_id:
        safe_session_id = re.sub(r"[^a-zA-Z0-9]", "", args.session_id)[:8]
        if safe_session_id:
            filename_stem = f"{filename_stem}-{safe_session_id}"
    output_paths: list[Path] = []

    jsonl_path = out_dir / f"{filename_stem}.jsonl"
    md_path = out_dir / f"{filename_stem}.md"
    llm_path = out_dir / f"{filename_stem}.llm.md"
    analysis_path = out_dir / f"{filename_stem}.analysis.jsonl"

    jsonl_text = build_jsonl(
        turns,
        filter_suspect=args.filter_suspect,
        sanitize_suspect=not args.no_sanitize,
        meta=None if args.no_meta else meta,
    )

    if args.format in ("jsonl", "both"):
        write_text_atomic(jsonl_path, jsonl_text)
        output_paths.append(jsonl_path)

    if args.format in ("markdown", "both"):
        write_text_atomic(
            md_path,
            build_markdown(
                args.title,
                turns,
                dual_track,
                args.language,
                sanitize_suspect=not args.no_sanitize,
                capture_integrity=args.capture_integrity,
                capture_issues=args.capture_issue,
                recorded_at=args.recorded_at,
            ),
        )
        output_paths.append(md_path)

    if args.format == "llm":
        write_text_atomic(llm_path, build_llm_package(meta, jsonl_text))
        output_paths.append(llm_path)

    if args.format == "analysis":
        write_text_atomic(
            analysis_path,
            build_analysis_jsonl(turns, meta=None if args.no_meta else meta),
        )
        output_paths.append(analysis_path)

    if args.format == "llm":
        primary_output = llm_path
    elif args.format == "analysis":
        primary_output = analysis_path
    elif args.format == "jsonl":
        primary_output = jsonl_path
    else:
        primary_output = md_path

    emit_progress(99)
    print(f"\nOutput: {primary_output}")
    if len(output_paths) > 1:
        print("Additional output: " + ", ".join(str(path) for path in output_paths if path != primary_output))
    print(
        f"Segments: {len(segments)}, Turns: {len(turns)}, "
        f"Duration: {format_time(max((s.end for s in segments), default=0))}"
    )

    if args.profile_memory and args.backend == "mlx":
        peak = _mlx_peak_mb()
        if peak is not None:
            print(f"[mem] mlx-peak-mb={peak:.0f}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
