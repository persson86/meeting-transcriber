"""Sinais textuais sobre turnos já transcritos (eco entre trilhas, duplicação).

Só biblioteca padrão e Python 3.9: é importado pelo pipeline
(`transcribe_meeting.py`) e pelo relatório somente leitura (`report.py`), que
roda com o python3 do sistema. Nada aqui altera texto; só mede e sinaliza.
"""
from __future__ import annotations

import re
from typing import Iterable, List, Optional, Sequence, Set, Tuple

_WORD_RE = re.compile(r"\w+", re.UNICODE)
_MARKER_RE = re.compile(r"\[[^\]]*\]")

# Eco: o alto-falante toca a fala remota e o microfone a capta com atraso
# pequeno (latência + desalinhamento entre trilhas de até ~2,7 s/h). Para um
# turno do mic, o trecho do sistema que pode ter vazado fica entre 3 s antes e
# 1 s depois dele: atraso do mic em relação ao sistema em [-1 s, +3 s].
ECHO_MIC_LEAD_MS = 1000
ECHO_MIC_LAG_MS = 3000
ECHO_MIN_SHARE = 0.5
ECHO_NGRAM = 3

SEAM_MIN_WORDS = 4
SEAM_WINDOW_WORDS = 30
SEAM_MAX_OFFSET = 3

# (trilha, início ms, fim ms, texto)
TurnTuple = Tuple[str, int, int, str]


def tokens(text: Optional[str]) -> List[str]:
    """Palavras normalizadas, sem marcadores como [inaudível] ou [risos]."""
    if not text:
        return []
    return [token.casefold() for token in _WORD_RE.findall(_MARKER_RE.sub(" ", text))]


def ngrams(words: Sequence[str], size: int = ECHO_NGRAM) -> List[Tuple[str, ...]]:
    return [tuple(words[index:index + size]) for index in range(len(words) - size + 1)]


def echo_share(mic_text: str, system_texts: Iterable[str], size: int = ECHO_NGRAM) -> Optional[float]:
    """Fração dos n-gramas do turno do mic presentes no texto do sistema.

    None quando o turno é curto demais para ter um n-grama (não avaliado).
    """
    mic_grams = ngrams(tokens(mic_text), size)
    if not mic_grams:
        return None
    system_grams: Set[Tuple[str, ...]] = set()
    for text in system_texts:
        system_grams.update(ngrams(tokens(text), size))
    if not system_grams:
        return 0.0
    hits = sum(1 for gram in mic_grams if gram in system_grams)
    return hits / len(mic_grams)


def echo_flags(
    turns: Sequence[TurnTuple],
    min_share: float = ECHO_MIN_SHARE,
    mic_lead_ms: int = ECHO_MIC_LEAD_MS,
    mic_lag_ms: int = ECHO_MIC_LAG_MS,
) -> List[bool]:
    """Para cada turno, True quando é do mic e repete a trilha do sistema."""
    system = sorted(
        (start, end, text) for track, start, end, text in turns if track == "system"
    )
    flags = []
    for track, start, end, text in turns:
        if track != "mic":
            flags.append(False)
            continue
        window_start = start - mic_lag_ms
        window_end = end + mic_lead_ms
        nearby = [
            sys_text for sys_start, sys_end, sys_text in system
            if sys_start <= window_end and sys_end >= window_start
        ]
        share = echo_share(text, nearby) if nearby else None
        flags.append(share is not None and share >= min_share)
    return flags


def echo_word_share(turns: Sequence[TurnTuple], flags: Sequence[bool]) -> Optional[float]:
    """Fração das palavras do mic que estão em turnos marcados como eco."""
    total = 0
    echoed = 0
    for (track, _, _, text), flagged in zip(turns, flags):
        if track != "mic":
            continue
        count = len(tokens(text))
        total += count
        if flagged:
            echoed += count
    if total == 0:
        return None
    return echoed / total


def repeats_tail(previous: Sequence[str], following: Sequence[str], min_words: int = SEAM_MIN_WORDS,
                 window: int = SEAM_WINDOW_WORDS, max_offset: int = SEAM_MAX_OFFSET) -> bool:
    """O começo de `following` repete as últimas ≥ min_words palavras de `previous`.

    Aceita até `max_offset` palavras antes da repetição (um "é", "então" que o
    decoder pôs na frente). É o sintoma da costura entre blocos; uma expressão
    comum no meio dos dois turnos não conta.
    """
    longest = min(len(previous), len(following), window)
    for size in range(longest, min_words - 1, -1):
        tail = list(previous[-size:])
        for offset in range(0, max_offset + 1):
            if list(following[offset:offset + size]) == tail:
                return True
    return False


def seam_duplicate_pairs(
    turns: Sequence[TurnTuple],
    min_words: int = SEAM_MIN_WORDS,
    window: int = SEAM_WINDOW_WORDS,
) -> Tuple[int, int]:
    """(pares com duplicação, pares avaliados) entre turnos consecutivos da mesma trilha."""
    by_track = {}
    for track, start, end, text in turns:
        by_track.setdefault(track, []).append((start, end, text))
    duplicated = 0
    pairs = 0
    for rows in by_track.values():
        rows.sort()
        for (_, _, previous_text), (_, _, next_text) in zip(rows, rows[1:]):
            previous_words = tokens(previous_text)
            next_words = tokens(next_text)
            if not previous_words or not next_words:
                continue
            pairs += 1
            if repeats_tail(previous_words, next_words, min_words, window):
                duplicated += 1
    return duplicated, pairs
