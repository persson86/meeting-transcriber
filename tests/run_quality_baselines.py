#!/usr/bin/env python3
"""Harness de regressão de qualidade sobre os audio-baselines.

Transcreve os fixtures de regressão e compara contra golden files aprovados:

  .venv/bin/python tests/run_quality_baselines.py                 # casos primary-regression
  .venv/bin/python tests/run_quality_baselines.py --all           # todos os casos
  .venv/bin/python tests/run_quality_baselines.py --case ID       # caso específico
  .venv/bin/python tests/run_quality_baselines.py --update-golden # aprova o output atual

Critérios por caso:
  1. Similaridade textual com o golden (SequenceMatcher) >= golden_min_similarity
     (manifest; default 0.90).
  2. Patologias não pioram além da margem: nº de turnos suspect, nº de
     [inaudível], padrões de runaway (KKKK/loops intra-token).
  3. Nenhum turno acima de MAX_TURN_MS.

Transcrição é pesada (Whisper large-v3) — este script é o gate manual/pré-commit,
não parte do pytest default.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from transcribe_meeting import token_has_runaway_substring  # noqa: E402

FIXTURE_ROOT = ROOT / "tests" / "fixtures" / "audio-baselines"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
SCRIPT = ROOT / "transcribe_meeting.py"

DEFAULT_MIN_SIMILARITY = 0.90
MAX_TURN_MS = 31_000           # 30s + margem de arredondamento
SUSPECT_REGRESSION_MARGIN = 2  # turnos suspect a mais que o golden tolerados


@dataclass
class QualityStats:
    n_turns: int
    n_suspect: int
    n_inaudible: int
    max_turn_ms: int
    runaway_turns: list[str]


def load_turns(jsonl_path: Path) -> list[dict]:
    turns = []
    for line in jsonl_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("type") == "meta":
            continue
        turns.append(row)
    return turns


def compute_stats(turns: list[dict]) -> QualityStats:
    runaway = []
    for turn in turns:
        text = turn["text"]
        if re.search(r"(.)\1{7,}", text, flags=re.IGNORECASE):
            runaway.append(text)
            continue
        if any(
            token_has_runaway_substring(token)
            for token in re.findall(r"\b\w{12,}\b", text)
        ):
            runaway.append(text)
    return QualityStats(
        n_turns=len(turns),
        n_suspect=sum(1 for turn in turns if turn["is_suspect"]),
        n_inaudible=sum(turn["text"].count("[inaudível]") for turn in turns),
        max_turn_ms=max((turn["end_ms"] - turn["start_ms"] for turn in turns), default=0),
        runaway_turns=runaway,
    )


def transcript_text(turns: list[dict]) -> str:
    return " ".join(turn["text"] for turn in turns)


def transcribe_case(case: dict, python: str, backend: str, extra_args: list[str]) -> Path:
    case_dir = FIXTURE_ROOT / case["id"]
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [
            python, str(SCRIPT),
            "--out", tmp,
            "--title", case["id"],
            "--format", "jsonl",
            "--backend", backend,
            *extra_args,
        ]
        mic = case_dir / "mic.wav"
        system = case_dir / "system.wav"
        if mic.exists():
            cmd += ["--mic", str(mic)]
        if system.exists():
            cmd += ["--system", str(system)]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(
                f"Transcrição de {case['id']} falhou (exit {result.returncode}):\n"
                f"{result.stderr or result.stdout}"
            )

        outputs = sorted(Path(tmp).glob("*.jsonl"))
        if not outputs:
            raise RuntimeError(f"Nenhum JSONL gerado para {case['id']}")
        # Move para fora do TemporaryDirectory antes de ele ser destruído
        final = Path(tempfile.mkstemp(suffix=".jsonl", prefix=f"{case['id']}-")[1])
        final.write_text(outputs[0].read_text(encoding="utf-8"), encoding="utf-8")
        return final


def check_case(case: dict, generated: Path) -> list[str]:
    """Retorna lista de falhas (vazia = caso aprovado)."""
    failures: list[str] = []
    golden_path = FIXTURE_ROOT / case["id"] / "golden.jsonl"
    turns = load_turns(generated)
    stats = compute_stats(turns)

    if stats.runaway_turns:
        failures.append(
            f"{len(stats.runaway_turns)} turno(s) com padrão runaway: "
            f"{stats.runaway_turns[0][:80]!r}"
        )
    if stats.max_turn_ms > MAX_TURN_MS:
        failures.append(f"turno de {stats.max_turn_ms}ms excede o limite de {MAX_TURN_MS}ms")

    if not golden_path.exists():
        failures.append(
            f"golden ausente ({golden_path.name}) — rode com --update-golden para aprovar"
        )
        return failures

    golden_turns = load_turns(golden_path)
    golden_stats = compute_stats(golden_turns)

    min_similarity = case.get("golden_min_similarity", DEFAULT_MIN_SIMILARITY)
    similarity = SequenceMatcher(
        None, transcript_text(golden_turns), transcript_text(turns)
    ).ratio()
    if similarity < min_similarity:
        failures.append(
            f"similaridade com golden {similarity:.3f} < {min_similarity:.2f}"
        )

    if stats.n_suspect > golden_stats.n_suspect + SUSPECT_REGRESSION_MARGIN:
        failures.append(
            f"suspects {stats.n_suspect} > golden {golden_stats.n_suspect} "
            f"+ margem {SUSPECT_REGRESSION_MARGIN}"
        )
    if stats.n_inaudible > golden_stats.n_inaudible + SUSPECT_REGRESSION_MARGIN:
        failures.append(
            f"[inaudível] {stats.n_inaudible} > golden {golden_stats.n_inaudible} "
            f"+ margem {SUSPECT_REGRESSION_MARGIN}"
        )

    print(
        f"    similaridade={similarity:.3f} turnos={stats.n_turns} "
        f"suspects={stats.n_suspect} inaudíveis={stats.n_inaudible} "
        f"turno_máx={stats.max_turn_ms / 1000:.1f}s"
    )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--case", action="append", default=[], help="ID de caso (pode repetir)")
    parser.add_argument("--all", action="store_true", help="Roda todos os casos do manifest")
    parser.add_argument(
        "--update-golden", action="store_true",
        help="Grava o output atual como golden.jsonl (aprovação manual)",
    )
    parser.add_argument("--backend", default="mlx", choices=["mlx", "faster-whisper"])
    parser.add_argument(
        "--python", default=sys.executable,
        help="Interpretador usado para transcrever (default: o atual)",
    )
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if args.case:
        cases = [case for case in manifest["cases"] if case["id"] in set(args.case)]
        missing = set(args.case) - {case["id"] for case in cases}
        if missing:
            parser.error(f"Casos não encontrados no manifest: {sorted(missing)}")
    elif args.all:
        cases = manifest["cases"]
    else:
        cases = [case for case in manifest["cases"] if case["role"] == "primary-regression"]

    overall_failures: dict[str, list[str]] = {}
    for case in cases:
        print(f"==> {case['id']} ({case['role']})", flush=True)
        generated = transcribe_case(case, args.python, args.backend, [])
        try:
            if args.update_golden:
                golden_path = FIXTURE_ROOT / case["id"] / "golden.jsonl"
                golden_path.write_text(
                    generated.read_text(encoding="utf-8"), encoding="utf-8"
                )
                stats = compute_stats(load_turns(golden_path))
                print(
                    f"    golden atualizado: turnos={stats.n_turns} "
                    f"suspects={stats.n_suspect} inaudíveis={stats.n_inaudible}"
                )
                if stats.runaway_turns:
                    print(
                        f"    ⚠ golden contém {len(stats.runaway_turns)} turno(s) runaway — revisar!"
                    )
                continue

            failures = check_case(case, generated)
            if failures:
                overall_failures[case["id"]] = failures
                for failure in failures:
                    print(f"    FAIL: {failure}")
            else:
                print("    OK")
        finally:
            generated.unlink(missing_ok=True)

    if overall_failures:
        print(f"\n{len(overall_failures)} caso(s) com regressão de qualidade.")
        return 1
    print("\nTodos os casos aprovados." if not args.update_golden else "\nGoldens atualizados.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
