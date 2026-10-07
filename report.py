#!/usr/bin/env python3
"""Relatório somente leitura das sessões gravadas: "a confiança voltou?" em números.

Lê `Sessions/*/manifest.json` (schemaVersion 1 e 2) e, quando existem, o
`.analysis.jsonl`/`.jsonl` da transcrição. Escreve uma linha por sessão em CSV
e um resumo por versão do app. Campo ausente sai como `n/d`.

Nunca imprime texto de falas, títulos, nomes nem caminhos de saída (o nome do
arquivo carrega o título). O dispositivo sai com possessivos mascarados.
Não escreve nada fora de `--out`. Python 3.9, só biblioteca padrão.

Uso:
    python3 -I report.py                       # CSV + resumo no stdout
    python3 -I report.py --out sessoes.csv     # CSV no arquivo, resumo no stdout
    python3 -I report.py --git-tags .          # infere a versão do app nas sessões v1
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import transcript_signals as signals  # noqa: E402

ND = "n/d"
DEFAULT_SESSIONS_DIR = Path.home() / "Library/Application Support/MeetingTranscriber/Sessions"
# Regra de integridade v2 (IntegrityRule.swift): 2 s num ponto ou 10 s somados.
MATERIAL_EVENT_S = 2.0
MATERIAL_LOSS_S = 10.0
SHORT_SESSION_S = 120.0
TRACKS = ("mic", "system")

COLUMNS = [
    "session", "date", "schema", "app_version", "version_source", "pipeline_version",
    "state", "duration_s", "duration_source", "first_signal_mic_s", "first_signal_system_s",
    "loss_mic_s", "loss_system_s", "label", "rearms", "rearm_blocked_stopped",
    "device", "echo_pct", "seam_dup_pairs", "seam_pairs", "untranscribed_blocks", "rtf",
    "asr_overlapped", "pipeline_dirty",
]

_DIARY_TIME = r"^\+(?P<t>\d+(?:\.\d+)?)s "
_SIGNAL_RE = re.compile(_DIARY_TIME + r"áudio com sinal chegando")
_REARM_RE = re.compile(_DIARY_TIME + r"rearme \(.*?rodando=(?P<running>true|false)")
_REARM_RECENT_RE = re.compile(_DIARY_TIME + r"rearme recente")
_SILENCE_RE = re.compile(_DIARY_TIME + r"silêncio inserido: (?P<s>\d+(?:\.\d+)?) ?s")
_CONFIGURED_RE = re.compile(_DIARY_TIME + r"configurado: (?P<device>.+?)(?: \(|$)")
_FALLBACK_RE = re.compile(_DIARY_TIME + r".+ sem sinal; usando (?P<device>.+?)(?: \(|$)")


# ---------------------------------------------------------------------------
# Leitura tolerante
# ---------------------------------------------------------------------------

def parse_date(value) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def number(value) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def integrity_of(manifest: dict) -> Optional[dict]:
    """Bloco `integrity` (regra v2) dentro de captureIntegrity; tolera topo do manifest."""
    capture = manifest.get("captureIntegrity")
    if isinstance(capture, dict) and isinstance(capture.get("integrity"), dict):
        return capture["integrity"]
    if isinstance(manifest.get("integrity"), dict):
        return manifest["integrity"]
    return None


def record_of(manifest: dict) -> dict:
    record = manifest.get("record")
    return record if isinstance(record, dict) else {}


def diary_of(manifest: dict) -> List[str]:
    capture = manifest.get("captureIntegrity")
    lines = capture.get("diagnostics") if isinstance(capture, dict) else None
    return [line for line in lines or [] if isinstance(line, str)]


def mask_device(name) -> Optional[str]:
    """Nome do aparelho sem o dono: "AirPods de Fulano" → "AirPods de <nome>"."""
    if isinstance(name, dict):
        name = name.get("name")
    if not isinstance(name, str) or not name.strip():
        return None
    text = name.strip()
    text = re.sub(r"^\S+?['’]s\s+", "<nome>'s ", text)
    text = re.sub(r"\s(de|do|da|von|di)\s.+$", r" \1 <nome>", text)
    return text


def read_transcript(manifest: dict) -> Tuple[Optional[dict], List[dict], List[dict]]:
    """(meta, turnos, blocos) do .analysis.jsonl, ou do .jsonl se não houver."""
    output = manifest.get("outputPath")
    if not isinstance(output, str) or not output:
        return None, [], []
    stem = output[:-3] if output.endswith(".md") else output
    for path in (stem + ".analysis.jsonl", stem + ".jsonl"):
        if not os.path.isfile(path):
            continue
        meta, turns, chunks = None, [], []
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    kind = row.get("type")
                    if kind == "meta" and meta is None:
                        meta = row
                    elif kind == "chunk":
                        chunks.append(row)
                    elif kind in ("turn", None) and "start_ms" in row:
                        turns.append(row)
        except OSError:
            continue
        return meta, turns, chunks
    return None, [], []


def turn_track(row: dict) -> Optional[str]:
    track = row.get("track")
    if track in TRACKS:
        return track
    speaker = row.get("speaker") or ""
    if speaker == "Você":
        return "mic"
    if speaker == "Interlocutor" or speaker.startswith("Remote_"):
        return "system"
    return None


def version_tuple(value) -> Optional[Tuple[int, ...]]:
    if not isinstance(value, str):
        return None
    parts = re.findall(r"\d+", value)
    return tuple(int(part) for part in parts[:3]) if len(parts) >= 2 else None


# ---------------------------------------------------------------------------
# Métricas por sessão
# ---------------------------------------------------------------------------

def diary_metrics(lines: Sequence[str]) -> dict:
    first_signal = None
    rearms = 0
    blocked = 0
    last_running = None
    silence = []
    device = None
    for line in lines:
        match = _SIGNAL_RE.match(line)
        if match and first_signal is None:
            first_signal = float(match.group("t"))
            continue
        match = _REARM_RE.match(line)
        if match:
            rearms += 1
            last_running = match.group("running") == "true"
            continue
        if _REARM_RECENT_RE.match(line):
            if last_running is False:
                blocked += 1
            continue
        match = _SILENCE_RE.match(line)
        if match:
            silence.append(float(match.group("s")))
            continue
        match = _FALLBACK_RE.match(line) or _CONFIGURED_RE.match(line)
        if match:
            device = match.group("device")
    return {
        "first_signal_mic": first_signal,
        "rearms": rearms if lines else None,
        "blocked": blocked if lines else None,
        "silence": silence,
        "device": device,
        "has_diary": bool(lines),
    }


def asr_metrics(manifest: dict, record: dict) -> Tuple[Optional[float], Optional[bool]]:
    """(segundos de ASR, ASR sobreposto a gravação). v1: completedAt − startedAt, sem sobreposição."""
    attempts = record.get("asrAttempts")
    if isinstance(attempts, list) and attempts:
        seconds = 0.0
        measured = False
        overlapped = False
        for attempt in attempts:
            if not isinstance(attempt, dict):
                continue
            overlapped = overlapped or attempt.get("overlappedRecording") is True
            start, end = parse_date(attempt.get("startedAt")), parse_date(attempt.get("endedAt"))
            if start and end:
                paused = number(attempt.get("pausedSeconds")) or 0.0
                seconds += max(0.0, (end - start).total_seconds() - paused)
                measured = True
        return (seconds if measured else None), overlapped
    start, end = parse_date(manifest.get("startedAt")), parse_date(manifest.get("completedAt"))
    if start and end:
        return max(0.0, (end - start).total_seconds()), None
    return None, None


def duration_of(integrity, record, meta) -> Tuple[Optional[float], str]:
    if integrity and number(integrity.get("sessionDurationS")) is not None:
        return number(integrity["sessionDurationS"]), "integrity"
    start, stop = parse_date(record.get("recordingStartedAt")), parse_date(record.get("recordingStoppedAt"))
    if start and stop:
        return max(0.0, (stop - start).total_seconds()), "record"
    if meta:
        if number(meta.get("audio_duration_ms")) is not None:
            return number(meta["audio_duration_ms"]) / 1000, "audio"
        if number(meta.get("duration_ms")) is not None:
            return number(meta["duration_ms"]) / 1000, "last_turn"
    return None, ND


def transcript_metrics(meta, turns, chunks) -> dict:
    """Eco e costura medidos com a mesma regra do pipeline (transcript_signals),
    para comparar transcrições de antes e depois da 0.10.0 na mesma régua."""
    tuples = []
    for row in turns:
        track = turn_track(row)
        start, end = number(row.get("start_ms")), number(row.get("end_ms"))
        if track is None or start is None or end is None:
            continue
        tuples.append((track, int(start), int(end), row.get("text") or ""))
    echo = None
    seam = None
    seam_pairs = None
    if tuples:
        if {"mic", "system"} <= {track for track, _, _, _ in tuples}:   # eco só existe com as duas trilhas
            echo = signals.echo_word_share(tuples, signals.echo_flags(tuples))
        seam, seam_pairs = signals.seam_duplicate_pairs(tuples)
    untranscribed = None
    pipeline = version_tuple((meta or {}).get("pipeline_version"))
    # `skipped_reason` só existe a partir da 0.10.0; antes disso, n/d (não zero).
    if pipeline and pipeline >= (0, 10, 0) and chunks:
        untranscribed = sum(1 for chunk in chunks if chunk.get("skipped_reason") == "empty_asr")
    return {"echo": echo, "seam": seam, "seam_pairs": seam_pairs, "untranscribed": untranscribed}


def infer_version(created: Optional[datetime], releases: Sequence[Tuple[datetime, str]]) -> Optional[str]:
    """Última versão publicada antes do início da gravação (aproximação por horário)."""
    if created is None:
        return None
    best = None
    for released_at, version in releases:
        if released_at <= created:
            best = version
    return best


def session_row(manifest: dict, releases: Sequence[Tuple[datetime, str]] = ()) -> dict:
    record = record_of(manifest)
    integrity = integrity_of(manifest)
    diary = diary_metrics(diary_of(manifest))
    meta, turns, chunks = read_transcript(manifest)
    text = transcript_metrics(meta, turns, chunks)
    created = parse_date(manifest.get("createdAt"))
    duration, duration_source = duration_of(integrity, record, meta)
    asr_seconds, overlapped = asr_metrics(manifest, record)

    version, source = record.get("appVersion"), "manifest"
    if not version:
        inferred = infer_version(created, releases)
        version, source = (inferred, "inferida") if inferred else (None, ND)

    tracks = (integrity or {}).get("tracks") if isinstance((integrity or {}).get("tracks"), dict) else {}
    first = {track: number((tracks.get(track) or {}).get("startDelayS")) for track in TRACKS}
    loss = {track: number((tracks.get(track) or {}).get("lossS")) for track in TRACKS}
    if first["mic"] is None:
        first["mic"] = diary["first_signal_mic"]

    capture = manifest.get("captureIntegrity") if isinstance(manifest.get("captureIntegrity"), dict) else {}
    session_id = manifest.get("id") if isinstance(manifest.get("id"), str) else ""
    pipeline_version = record.get("pipelineVersion") or (meta or {}).get("pipeline_version")
    dirty = record.get("pipelineDirty")

    return {
        "session": session_id[:8] or ND,
        "date": created.astimezone().strftime("%Y-%m-%d %H:%M") if created else ND,
        "schema": manifest.get("schemaVersion", ND),
        "app_version": version,
        "version_source": source,
        "pipeline_version": pipeline_version,
        "state": manifest.get("state"),
        "duration_s": duration,
        "duration_source": duration_source,
        "first_signal_mic_s": first["mic"],
        "first_signal_system_s": first["system"],
        "loss_mic_s": loss["mic"],
        "loss_system_s": loss["system"],
        "label": capture.get("status"),
        "rearms": diary["rearms"],
        "rearm_blocked_stopped": diary["blocked"],
        "device": mask_device(record.get("inputDevice")) or mask_device(diary["device"]),
        "echo_pct": None if text["echo"] is None else 100 * text["echo"],
        "seam_dup_pairs": text["seam"],
        "seam_pairs": text["seam_pairs"],
        "untranscribed_blocks": text["untranscribed"],
        "rtf": (asr_seconds / duration) if asr_seconds is not None and duration else None,
        "asr_overlapped": overlapped,
        "pipeline_dirty": dirty if isinstance(dirty, bool) else None,
        # Uso interno do resumo (não vai ao CSV).
        "_loss_measured": measured_loss(integrity, diary),
    }


def measured_loss(integrity: Optional[dict], diary: dict) -> Optional[bool]:
    """Perda material pela regra v2. v1: só o que o diário mede (1º sinal do mic, silêncio inserido)."""
    tracks = (integrity or {}).get("tracks")
    if isinstance(tracks, dict) and tracks:
        for values in tracks.values():
            if not isinstance(values, dict):
                continue
            if (number(values.get("lossS")) or 0) >= MATERIAL_LOSS_S:
                return True
            for interval in values.get("intervals") or []:
                if isinstance(interval, dict) and (number(interval.get("durS")) or 0) >= MATERIAL_EVENT_S:
                    return True
        return False
    if not diary["has_diary"]:
        return None
    start = diary["first_signal_mic"] or 0.0
    gaps = diary["silence"]
    if start >= MATERIAL_EVENT_S or any(gap >= MATERIAL_EVENT_S for gap in gaps):
        return True
    return start + sum(gaps) >= MATERIAL_LOSS_S


# ---------------------------------------------------------------------------
# Saída
# ---------------------------------------------------------------------------

def cell(value) -> str:
    if value is None or value == "":
        return ND
    if isinstance(value, bool):
        return "sim" if value else "não"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def write_csv(rows: Iterable[dict], handle) -> None:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(COLUMNS)
    for row in rows:
        writer.writerow([cell(row.get(column)) for column in COLUMNS])


def _median(values: List[float]) -> str:
    return f"{statistics.median(values):.1f}" if values else ND


def _version_key(label: str):
    parsed = version_tuple(label.lstrip("~"))
    return (0, parsed) if parsed else (1, ())


def summary(rows: Sequence[dict]) -> str:
    groups: Dict[str, List[dict]] = {}
    for row in rows:
        version = row.get("app_version")
        label = ND if not version else (("~" if row["version_source"] == "inferida" else "") + str(version))
        groups.setdefault(label, []).append(row)

    lines = [
        f"Sessões: {len(rows)} (manifest v2: {sum(1 for r in rows if r.get('schema') == 2)})",
        "Por versão do app (~ = inferida pelo horário; reuniões ≥ 2 min nas colunas de perda):",
        "versão | n | ≥2min | degraded | perda medida | perda sem aviso | degraded sem perda | "
        "1º sinal mic (med. s) | eco % (med.) | costura dup./pares | sem texto | RTF (med.) | ASR sobreposto | pipeline sujo",
    ]
    for label in sorted(groups, key=_version_key):
        group = groups[label]
        long = [r for r in group if r.get("duration_s") is not None and r["duration_s"] >= SHORT_SESSION_S]
        degraded = [r for r in long if r.get("label") == "degraded"]
        known = [r for r in long if r["_loss_measured"] is not None]
        lost = [r for r in known if r["_loss_measured"]]
        silent = [r for r in lost if r.get("label") == "complete"]
        false_alarm = [r for r in known if not r["_loss_measured"] and r.get("label") == "degraded"]

        def count(values, total):
            return f"{len(values)}/{len(total)}" if total else ND

        seam = [(r["seam_dup_pairs"], r["seam_pairs"]) for r in group if r.get("seam_dup_pairs") is not None]
        seam_dup, seam_total = sum(d for d, _ in seam), sum(p for _, p in seam)
        blank = [r["untranscribed_blocks"] for r in group if r.get("untranscribed_blocks") is not None]
        overlapped = [r for r in group if r.get("asr_overlapped") is not None]
        dirty = [r for r in group if r.get("pipeline_dirty") is not None]
        lines.append(" | ".join([
            label,
            str(len(group)),
            str(len(long)),
            count(degraded, long),
            count(lost, known),
            count(silent, known),
            count(false_alarm, known),
            _median([r["first_signal_mic_s"] for r in group if r.get("first_signal_mic_s") is not None]),
            _median([r["echo_pct"] for r in group if r.get("echo_pct") is not None]),
            f"{seam_dup}/{seam_total} ({100 * seam_dup / seam_total:.1f}%)" if seam_total else ND,
            str(sum(blank)) if blank else ND,
            _median([r["rtf"] for r in group if r.get("rtf") is not None]),
            count([r for r in overlapped if r["asr_overlapped"]], overlapped),
            count([r for r in dirty if r["pipeline_dirty"]], dirty),
        ]))
    lines.append(
        "Limites: v1 não tem lossS nem atraso do sistema; a perda v1 vem só do diário "
        "(1º sinal do mic e silêncio inserido) e a RTF v1 inclui pausas. n/d = sem o dado."
    )
    return "\n".join(lines) + "\n"


def load_manifests(sessions_dir: Path) -> Tuple[List[dict], int]:
    manifests, unreadable = [], 0
    for path in sorted(sessions_dir.glob("*/manifest.json")):
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            unreadable += 1
            continue
        if isinstance(data, dict):
            manifests.append(data)
        else:
            unreadable += 1
    return manifests, unreadable


def git_releases(repo: Path) -> List[Tuple[datetime, str]]:
    """Tags vX.Y.Z com a data de criação (somente leitura via git for-each-ref)."""
    try:
        output = subprocess.run(
            ["git", "-C", str(repo), "for-each-ref", "refs/tags",
             "--format=%(creatordate:iso-strict) %(refname:short)"],
            capture_output=True, text=True, check=True, timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return parse_releases(output.splitlines())


def parse_releases(lines: Iterable[str]) -> List[Tuple[datetime, str]]:
    releases = []
    for line in lines:
        parts = line.strip().split()
        if len(parts) != 2:
            continue
        released_at = parse_date(parts[0])
        if released_at and re.match(r"^v?\d+\.\d+", parts[1]):
            releases.append((released_at, parts[1].lstrip("v")))
    return sorted(releases)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Relatório somente leitura das sessões (CSV + resumo).")
    parser.add_argument("--sessions-dir", type=Path, default=DEFAULT_SESSIONS_DIR)
    parser.add_argument("--out", type=Path, help="Arquivo CSV; sem ele, o CSV sai no stdout antes do resumo")
    parser.add_argument("--git-tags", type=Path, metavar="REPO",
                        help="Infere a versão do app nas sessões v1 pelas tags do repositório")
    args = parser.parse_args(argv)

    if not args.sessions_dir.is_dir():
        print(f"Pasta de sessões não encontrada: {args.sessions_dir}", file=sys.stderr)
        return 2
    manifests, unreadable = load_manifests(args.sessions_dir)
    releases = git_releases(args.git_tags) if args.git_tags else []
    rows = sorted((session_row(manifest, releases) for manifest in manifests), key=lambda r: r["date"])

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="") as handle:
            write_csv(rows, handle)
    else:
        buffer = io.StringIO()
        write_csv(rows, buffer)
        sys.stdout.write(buffer.getvalue() + "\n")
    sys.stdout.write(summary(rows))
    if unreadable:
        print(f"Manifests ilegíveis ignorados: {unreadable}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
