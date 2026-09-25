#!/usr/bin/env python3
"""Revisão de transcrições: localizar um turno e ouvir o trecho da trilha certa.

Uso:
    review_turns.py ARQUIVO.jsonl                 # lista turnos sinalizados
    review_turns.py ARQUIVO.jsonl --at 48:10      # toca o turno em 48:10
    review_turns.py ARQUIVO.jsonl --at 48:10 --track system
    review_turns.py ARQUIVO.jsonl --turn 131      # toca o turno nº 131 da lista
    review_turns.py ARQUIVO.jsonl --range 48:05-48:30 --track system
    review_turns.py ARQUIVO.jsonl --chunks [--at 48:10]

ARQUIVO pode ser o .md, o .jsonl ou o .analysis.jsonl de uma transcrição; o
.analysis.jsonl de mesmo basename é preferido quando existe (traz a trilha
explícita, os sinais de qualidade e o diagnóstico por bloco).

Os tempos são os da transcrição (os mesmos do Markdown). O áudio vem da sessão
do app (Sessions/<session_id>/) ou da pasta arquivada ao lado da transcrição, ou
de --audio-dir. Sem áudio, a ferramenta avisa e sai com código 3: nada é dado
como conferido.

Só usa a biblioteca padrão: roda com o python3 do sistema.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import wave
from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "MeetingTranscriber"
CLIP_DIR = Path.home() / "Library" / "Caches" / "MeetingTranscriber" / "clips"

# Sinais que justificam escuta. `remote_unclustered` fica de fora: marca todo
# turno remoto quando não há separação de falantes, então não filtra nada.
TRIAGE_FLAGS = ("suspect", "low_confidence", "inaudible", "raw_differs", "sanitized")
LOW_CONFIDENCE = 0.6
EXIT_NO_AUDIO = 3


# ---------------------------------------------------------------------------
# Leitura
# ---------------------------------------------------------------------------

def resolve_transcript(path: Path) -> Path:
    """Prefere o .analysis.jsonl irmão; aceita .md, .jsonl ou .analysis.jsonl."""
    name = path.name
    for suffix in (".analysis.jsonl", ".jsonl", ".md"):
        if name.endswith(suffix):
            stem = name[: -len(suffix)]
            break
    else:
        raise SystemExit(f"Formato não reconhecido: {path} (use .md, .jsonl ou .analysis.jsonl)")
    for candidate in (f"{stem}.analysis.jsonl", f"{stem}.jsonl"):
        candidate_path = path.with_name(candidate)
        if candidate_path.is_file():
            return candidate_path
    raise SystemExit(f"Nenhum JSONL encontrado ao lado de {path}")


def infer_track(speaker: str) -> str:
    if speaker == "Você":
        return "mic"
    if speaker == "Interlocutor" or speaker.startswith("Remote_"):
        return "system"
    return "unknown"


def turn_flags(row: dict) -> list[str]:
    if "quality_flags" in row:
        return list(row["quality_flags"])
    # JSONL padrão: reconstrói os mesmos sinais a partir dos campos disponíveis.
    flags = []
    if row.get("is_suspect"):
        flags.append("suspect")
    confidence = row.get("confidence", -1.0)
    if confidence != -1.0 and confidence < LOW_CONFIDENCE:
        flags.append("low_confidence")
    if "[inaudível]" in row.get("text", ""):
        flags.append("inaudible")
    if "raw_text" in row:
        flags.append("raw_differs")
    return flags


def load(path: Path) -> tuple[dict, list[dict], list[dict]]:
    meta: dict = {}
    turns: list[dict] = []
    chunks: list[dict] = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            kind = row.get("type")
            if kind == "meta":
                meta = row
            elif kind == "chunk":
                chunks.append(row)
            elif kind in ("turn", None):
                row["n"] = len(turns) + 1
                if row.get("track") in ("mic", "system"):
                    row["track_source"] = "recorded"
                else:
                    row["track"] = infer_track(row.get("speaker", ""))
                    row["track_source"] = "inferred"
                row["flags"] = turn_flags(row)
                turns.append(row)
    # Trilha única: o pipeline rotula "Áudio" sem trilha; a meta diz qual foi.
    single = meta.get("tracks")
    if single in ("mic", "system"):
        for row in turns:
            if row["track"] == "unknown":
                row["track"] = single
    return meta, turns, chunks


# ---------------------------------------------------------------------------
# Tempo
# ---------------------------------------------------------------------------

def parse_time(value: str) -> int:
    """'48:10', '1:02:03' ou '2890.5' → ms."""
    value = value.strip()
    try:
        parts = [float(p) for p in value.split(":")]
    except ValueError:
        raise SystemExit(f"Tempo inválido: {value!r} (use mm:ss, h:mm:ss ou segundos)")
    if len(parts) == 1:
        return round(parts[0] * 1000)
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return round(seconds * 1000)


def fmt(ms: int) -> str:
    total = max(0, ms) // 1000
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def parse_range(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"\s*([\d:.]+)\s*-\s*([\d:.]+)\s*", value)
    if not match:
        raise SystemExit(f"Intervalo inválido: {value} (use mm:ss-mm:ss)")
    start, end = parse_time(match.group(1)), parse_time(match.group(2))
    if end <= start:
        raise SystemExit(f"Intervalo vazio: {value}")
    return start, end


# ---------------------------------------------------------------------------
# Áudio
# ---------------------------------------------------------------------------

def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def locate_audio(meta: dict, transcript: Path, audio_dir: Path | None) -> tuple[dict, dict, list[str]]:
    """Devolve ({track: wav}, {track: offset_ms}, notas sobre a origem)."""
    notes: list[str] = []
    candidates: list[tuple[Path, dict]] = []
    if audio_dir is not None:
        info = _read_json(audio_dir / "manifest.json") or _read_json(audio_dir / "metadata.json")
        candidates.append((audio_dir, info))
    session_id = meta.get("session_id")
    if session_id and re.fullmatch(r"[0-9A-Fa-f-]{36}", session_id):
        session_dir = APP_SUPPORT / "Sessions" / session_id
        manifest = _read_json(session_dir / "manifest.json")
        if manifest:
            candidates.append((session_dir, manifest))
            output_path = manifest.get("outputPath")
            if output_path:
                archive = Path(output_path).with_suffix("")
                candidates.append((archive, _read_json(archive / "metadata.json")))
    # Pasta arquivada ao lado do próprio arquivo (quando ele não foi copiado).
    stem = transcript.name.split(".")[0]
    local_archive = transcript.with_name(stem)
    candidates.append((local_archive, _read_json(local_archive / "metadata.json")))

    for directory, info in candidates:
        wavs = {}
        for track in ("mic", "system"):
            declared = info.get(f"{track}Path")
            path = Path(declared) if declared else directory / f"{track}.wav"
            if path.is_file():
                wavs[track] = path
        if wavs:
            notes.append(f"áudio: {directory}")
            offsets = {"mic": 0.0, "system": 0.0}
            recorded = meta.get("track_offsets_ms")
            if isinstance(recorded, dict):
                offsets.update({k: float(v) for k, v in recorded.items() if k in offsets})
                notes.append("offsets: registrados na transcrição")
            elif "sysOffsetMs" in info:
                offsets["system"] = float(info["sysOffsetMs"])
                notes.append("offsets: da sessão do app")
            else:
                notes.append("offsets: desconhecidos, assumindo 0 ms")
            return wavs, offsets, notes
    return {}, {}, notes


def write_clip(wav_path: Path, start_ms: int, end_ms: int, out_path: Path) -> tuple[int, int]:
    """Recorta [start_ms, end_ms) do WAV (tempo do próprio arquivo). Devolve o intervalo efetivo."""
    with wave.open(str(wav_path), "rb") as src:
        rate = src.getframerate()
        total = src.getnframes()
        first = max(0, min(total, int(start_ms * rate / 1000)))
        last = max(first, min(total, int(end_ms * rate / 1000)))
        src.setpos(first)
        frames = src.readframes(last - first)
        params = src.getparams()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out_path), "wb") as dst:
        dst.setparams(params)
        dst.writeframes(frames)
    return round(first * 1000 / rate), round(last * 1000 / rate)


def clip_window(start_ms: int, end_ms: int, at_ms: int | None, margin_ms: int, max_ms: int) -> tuple[int, int]:
    lo, hi = start_ms - margin_ms, end_ms + margin_ms
    if at_ms is not None and hi - lo > max_ms:
        # Turno longo: centra no instante pedido em vez de tocar tudo.
        lo = max(lo, at_ms - max_ms // 2)
        hi = lo + max_ms
    return max(0, lo), hi


# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

def preview(text: str, width: int = 90) -> str:
    text = " ".join(text.split())
    return text if len(text) <= width else text[: width - 1] + "…"


def print_turn(turn: dict, full: bool = False) -> None:
    track = turn["track"] + ("?" if turn["track_source"] == "inferred" else "")
    flags = ",".join(f for f in turn["flags"] if f in TRIAGE_FLAGS)
    head = f"#{turn['n']:<4} [{fmt(turn['start_ms'])}–{fmt(turn['end_ms'])}] {track:<7} {turn.get('speaker', '')}"
    print(head + (f"  ({flags})" if flags else ""))
    text = turn.get("text", "")
    print("      " + (text if full else preview(text)))
    raw = turn.get("raw_text")
    if full and raw and raw != text:
        print("      bruto: " + raw)


def cmd_list(turns: list[dict], only: set[str]) -> None:
    flagged = [t for t in turns if only.intersection(t["flags"])]
    for turn in flagged:
        print_turn(turn)
    print(f"\n{len(flagged)} de {len(turns)} turnos sinalizados ({', '.join(sorted(only))}).")
    print("Lista curta não valida a reunião: turnos sem sinal também podem estar errados (use --at).")


def cmd_chunks(chunks: list[dict], at_ms: int | None, track: str | None) -> None:
    if not chunks:
        print("Sem diagnóstico por bloco (anterior à 0.9.0, sem --with-analysis ou trilha transcrita inteira).")
        return
    rows = [c for c in chunks if not track or c["track"] == track]
    if at_ms is not None:
        rows = [c for c in rows if c["slice_start_ms"] <= at_ms <= c["end_ms"]]
    for c in rows:
        parts = [f"{c['track']:<6} bloco {c['index']:<4} {fmt(c['start_ms'])}–{fmt(c['end_ms'])}"]
        if c.get("skipped"):
            parts.append("silêncio, pulado")
        else:
            parts.append("termos no prompt" if c.get("hotwords") else "sem termos no prompt")
            parts.append(f"prompt anterior {c.get('prompt_tail_chars', 0)} chars")
            retry = c.get("coverage_retry")
            if retry:
                verdict = "adotado" if retry["used"] else "descartado"
                parts.append(
                    f"retry de cobertura {verdict} "
                    f"({retry['covered_ms'] / 1000:.1f}s → {retry['retry_covered_ms'] / 1000:.1f}s "
                    f"de {retry['speech_ms'] / 1000:.1f}s de fala)"
                )
            if c.get("seam_dropped"):
                parts.append(f"{c['seam_dropped']} segmento(s) descartado(s) na costura")
        print(" · ".join(parts))
    if not rows:
        print("Nenhum bloco cobre esse ponto.")


def select_turns(turns: list[dict], at_ms: int, track: str | None) -> list[dict]:
    pool = [t for t in turns if not track or t["track"] == track]
    # 1) o turno cujo cabeçalho no Markdown é esse mm:ss (o .md trunca o início);
    # 2) quem contém o instante (as duas trilhas podem falar juntas);
    # 3) tolerância de 1 s para um mm:ss que cai numa pausa.
    header = [t for t in pool if t["start_ms"] // 1000 == at_ms // 1000]
    if header:
        return header
    for tolerance in (0, 1000):
        hits = [t for t in pool if t["start_ms"] - tolerance <= at_ms <= t["end_ms"] + tolerance]
        if hits:
            return hits
    if not pool:
        return []
    return [min(pool, key=lambda t: min(abs(t["start_ms"] - at_ms), abs(t["end_ms"] - at_ms)))]


def play(paths: list[Path], no_play: bool) -> None:
    if no_play:
        return
    player = "afplay" if sys.platform == "darwin" else None
    if not player:
        print("Reprodução automática só no macOS; use o caminho acima.")
        return
    for path in paths:
        try:
            subprocess.run([player, str(path)], check=False)
        except KeyboardInterrupt:
            print("\ninterrompido")
            return


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Lista turnos sinalizados e toca o trecho da trilha certa.")
    parser.add_argument("transcript", type=Path, help=".md, .jsonl ou .analysis.jsonl")
    selector = parser.add_mutually_exclusive_group()
    selector.add_argument("--at", help="instante (mm:ss, h:mm:ss ou segundos) do turno a ouvir")
    selector.add_argument("--turn", type=int, help="número do turno na listagem")
    selector.add_argument("--range", help="intervalo livre mm:ss-mm:ss (exige --track com duas trilhas)")
    parser.add_argument("--track", choices=["mic", "system"], help="restringe à trilha")
    parser.add_argument("--chunks", action="store_true", help="mostra o diagnóstico por bloco")
    parser.add_argument("--flags", default=",".join(TRIAGE_FLAGS), help="sinais usados na listagem")
    parser.add_argument("--margin", type=float, default=2.0, help="margem em segundos (default 2)")
    parser.add_argument("--max-sec", type=float, default=40.0, help="duração máxima do clipe com --at")
    parser.add_argument("--audio-dir", type=Path, help="pasta com mic.wav/system.wav, se não for a da sessão")
    parser.add_argument("--no-play", action="store_true", help="só gera o clipe e mostra o caminho")
    args = parser.parse_args(argv)

    transcript = resolve_transcript(args.transcript.expanduser())
    meta, turns, chunks = load(transcript)
    at_ms = parse_time(args.at) if args.at else None
    print(f"{transcript.name} · {len(turns)} turnos · pipeline {meta.get('pipeline_version', '?')}")

    if args.chunks:
        cmd_chunks(chunks, at_ms, args.track)
        return 0

    if at_ms is None and args.turn is None and args.range is None:
        only = {f.strip() for f in args.flags.split(",") if f.strip()}
        cmd_list(turns, only)
        return 0

    # Monta os pedidos de clipe: (trilha, início e fim na linha do tempo da transcrição).
    requests: list[tuple[str, int, int, dict | None]] = []
    margin_ms = round(args.margin * 1000)
    if args.range:
        start, end = parse_range(args.range)
        tracks = [args.track] if args.track else sorted({t["track"] for t in turns} - {"unknown"})
        if len(tracks) != 1:
            print("Com duas trilhas, --range exige --track mic|system.", file=sys.stderr)
            return 2
        requests.append((tracks[0], start, end, None))
    else:
        if args.turn is not None:
            chosen = [t for t in turns if t["n"] == args.turn]
            if not chosen:
                print(f"Turno #{args.turn} não existe (1–{len(turns)}).", file=sys.stderr)
                return 2
        else:
            chosen = select_turns(turns, at_ms, args.track)
            if not chosen:
                print("Nenhum turno nessa trilha.", file=sys.stderr)
                return 2
        for turn in chosen:
            lo, hi = clip_window(turn["start_ms"], turn["end_ms"], at_ms, margin_ms, round(args.max_sec * 1000))
            requests.append((turn["track"], lo, hi, turn))

    for _, _, _, turn in requests:
        if turn:
            print_turn(turn, full=True)
    if any(turn and turn["track_source"] == "inferred" for *_, turn in requests):
        print("Trilha inferida pelo rótulo do falante (JSONL sem campo track).")

    wavs, offsets, notes = locate_audio(meta, transcript, args.audio_dir.expanduser() if args.audio_dir else None)
    if not wavs:
        print(
            "\nÁudio indisponível para esta sessão: revisão só textual, nada foi conferido no áudio. "
            "Use --audio-dir se os WAVs estiverem em outra pasta.",
            file=sys.stderr,
        )
        return EXIT_NO_AUDIO
    for note in notes:
        print(note)

    session = (meta.get("session_id") or transcript.name.split(".")[0])[:8]
    clips: list[Path] = []
    for track, lo, hi, _ in requests:
        if track == "unknown" and len(wavs) == 1:
            # JSONL sem trilha e sem meta (ex.: falante renomeado): só há um áudio.
            track = next(iter(wavs))
            print(f"Trilha desconhecida; usando o único áudio encontrado ({track}).")
        wav = wavs.get(track)
        if wav is None:
            print(f"Trilha {track} ausente no áudio encontrado; nada tocado para ela.", file=sys.stderr)
            continue
        offset = round(offsets.get(track, 0.0))
        out = CLIP_DIR / f"{session}-{track}-{lo}-{hi}.wav"
        got_lo, got_hi = write_clip(wav, lo - offset, hi - offset, out)
        if got_hi <= got_lo:
            print(f"Intervalo fora do áudio da trilha {track}.", file=sys.stderr)
            continue
        print(f"▶ {track} {fmt(lo)}–{fmt(hi)} (margem {args.margin:g}s) → {out}")
        clips.append(out)
    if not clips:
        return EXIT_NO_AUDIO
    play(clips, args.no_play)
    return 0


if __name__ == "__main__":
    sys.exit(main())
