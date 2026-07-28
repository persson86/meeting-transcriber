# Meeting Transcriber

Local macOS meeting transcription with separate microphone and system-audio
tracks.

## Overview

The project has two parts:

- **MeetingTranscriber.app**: a SwiftUI menu bar app that records microphone and
  system audio at the same time, measures the offset between both tracks, and
  queues transcription jobs after recording stops.
- **transcribe_meeting.py**: a Python transcription pipeline that receives one
  or two `.wav` files, runs Whisper with speech-island chunking, and writes
  JSONL turns for downstream LLM use. A Markdown transcript is also written by
  default.

Speaker labels are track based: microphone audio is labeled `Você`, system audio
is labeled `Interlocutor`. Optional local clustering can split the system track
into heuristic `Remote_A`, `Remote_B`, etc. labels.

## Requirements

- macOS 13 or newer
- Python 3.9 or newer
- Screen & System Audio Recording permission (system audio is captured natively
  via ScreenCaptureKit; no virtual audio device is required)
- Calendar permission is optional and is requested only when using the automatic
  meeting-title action
- Apple Silicon is recommended for the default MLX backend

## Setup

Create or open the folder where the checkout and transcripts should live, then
run the installer from there:

```bash
mkdir -p ~/Transcricoes
cd ~/Transcricoes
curl -fsSL https://raw.githubusercontent.com/persson86/meeting-transcriber/main/install.sh | bash
```

The installer creates or updates `./meeting-transcriber`, creates
`./transcriptions`, installs Python dependencies, builds the menu bar app,
copies it to `~/Applications/MeetingTranscriber.app`, configures the app to use
those local paths, and opens it.

For a local checkout, run:

```bash
make install   # install dependencies, app, and local output paths
make test      # run the local test gate
```

The app defaults to a source checkout at `~/meeting-transcriber`, with Python at
`.venv/bin/python` and the script at `transcribe_meeting.py`. You can override
paths without recompiling:

```bash
defaults write <bundle-id> projectRoot /path/to/meeting-transcriber
defaults write <bundle-id> pythonPath /path/to/python
defaults write <bundle-id> scriptPath /path/to/transcribe_meeting.py
defaults write <bundle-id> defaultOutputDirectory ~/Transcriptions
defaults write <bundle-id> contextTerms -array "ProjectName" "CustomerName"
defaults write <bundle-id> maxConcurrentTranscriptions 2
defaults write <bundle-id> mlxModel mlx-community/whisper-large-v3-mlx
defaults write <bundle-id> transcriptionBackend mlx
defaults write <bundle-id> debugMemoryLogging -bool YES
defaults write <bundle-id> secondBrainPath /path/to/second-brain
```

`maxConcurrentTranscriptions` controls how many transcription processes run at
the same time. The default is `1` to keep the Mac responsive; values above `3`
are capped.

### Model / memory

The MLX model is the biggest single memory consumer, and on a 16 GB Mac that
pressure is what makes the machine sluggish once transcription starts. The app
defaults to **`whisper-large-v3` 4-bit**, chosen from a real PT-BR benchmark on
an M3 (16 GB):

| Model | Peak MLX memory | Time | Quality vs fp16 |
| --- | --- | --- | --- |
| `large-v3` fp16 | 3677 MB | baseline | reference |
| `large-v3` 8-bit | 2451 MB (−33%) | +30% | identical |
| `large-v3-turbo` | 2189 MB (−40%) | −31% | comparable, drifts more on names/terms |
| **`large-v3` 4-bit (default)** | **1717 MB (−53%)** | +21% | near-identical (0.984) |

4-bit roughly halves model memory with no meaningful quality loss (the extra time
runs in the background queue). Override with `mlxModel`:

- Maximum quality: `mlxModel mlx-community/whisper-large-v3-mlx` (fp16).
- Fastest: `mlxModel mlx-community/whisper-large-v3-turbo` (accepts a small
  quality drop on proper nouns).
- Any quantized repo works — `mlx_whisper` applies the repo's `config.json`
  quantization automatically. The first run downloads the model.

`debugMemoryLogging -bool YES` logs PID, track sizes, and concurrency to Console;
pair with the CLI `--profile-memory` flag (RSS per phase plus the real MLX peak on
stderr) to measure before changing the model.

## Updating to the Latest Version

> [!TIP]
> Already installed and want the newest features (transcription queue reliably
> visible again with live progress %, confirmation before cancelling an
> in-flight job, transcripts open in Sublime Text by default, more resilient
> system-audio capture)? Re-run the installer from the **same folder** you used
> the first time — it updates your existing checkout in place, it does not
> start over.

```bash
cd ~/Transcricoes   # the folder you used the first time you installed
curl -fsSL https://raw.githubusercontent.com/persson86/meeting-transcriber/main/install.sh | bash
```

This pulls the latest changes into `./meeting-transcriber`, rebuilds the app,
reinstalls it to `~/Applications/MeetingTranscriber.app`, and reopens it — your
output folder and settings are untouched. If you're not sure which folder you
used, look in your home folder for a `meeting-transcriber` folder (Finder →
Go → Home).

Prefer the manual route from an existing checkout?

```bash
cd meeting-transcriber
git pull --ff-only
make install
```

## Backends

| Backend | Speed | Robustness |
| --- | --- | --- |
| `mlx` (default) | Fast on Apple Silicon with Metal | Greedy-only; no beam search |
| `faster-whisper` | Usually slower on CPU | Supports `beam_size=5`, which can help with noisy audio |

MLX is the default because it is fast on Apple Silicon. For noisy audio,
overlapping speech, or unstable calls, `--backend faster-whisper` can be more
conservative at the cost of processing time.

The pipeline also supports meeting-specific vocabulary through `--context-term`,
`--hotword`, `--replace`, and `--config-json`.

## Permissions

On first launch the app asks for **Screen & System Audio Recording** (used only
to capture system audio) and, on the first recording, **Microphone** access.
Calendar access is requested separately, only after clicking
**Usar próxima reunião do Calendar**.

If recording fails with a permission error, enable the app in System Settings →
Privacy & Security → Screen & System Audio Recording and try again. If the app
does not appear in that list, click the **+** button below the list and select
`MeetingTranscriber.app`. After changing the permission, restart the app.

If only one track is captured — for example the microphone stops after an audio
device/route change mid-meeting — the app shows a warning and still transcribes
the track it has, instead of silently producing an incomplete transcript. The
recorder also re-arms the microphone tap on device/route changes to avoid losing
the track in the first place.

Note for source builds: the permission is tied to the app's code signature.
Ad-hoc signatures change on every build, which makes macOS silently revoke the
permission and hide the app from the list. Run `make setup-cert` once (in
`MeetingTranscriber/`) to create a stable self-signed certificate so the
permission survives rebuilds. If the app got into the hidden/denied state, reset
it with `tccutil reset ScreenCapture <bundle-id>` and relaunch.

## Menu Bar App

1. Open `MeetingTranscriber.app`.
2. Click the microphone icon in the macOS menu bar.
3. Enter a meeting title or click **Usar próxima reunião do Calendar**.
4. Click **Iniciar gravação** to begin recording.
5. Click **Parar e adicionar à fila** to save audio and enqueue the transcription.
6. Follow progress in the **Transcrições** section. JSONL and Markdown files are
   written to the configured output directory.

The Calendar action looks at the next 24 hours and uses the earliest upcoming
non-cancelled, non-all-day event that you accepted, or that you organized with
other participants. It fills the title field but never starts recording
automatically. If no eligible event is found, the existing title is preserved
and the app shows a warning.

To process an iPhone recording manually, click **Processar arquivo de áudio…**. The
file picker opens in Downloads by default; choose the 16 kHz WAV and leave the
app open while the job runs. The app copies the selected file into its temporary
queue and never changes or deletes the original in Downloads. A single imported
track uses the neutral speaker label `Áudio`.

After a recording stops, the app saves the WAV files, returns to the ready state,
and keeps processing previous jobs in the background. This lets you start another
meeting while earlier recordings are still being transcribed.

The wider menu uses native large controls and larger action targets for better
readability. It shows recent jobs as queued, running, completed, or failed. A running
job shows a live progress percentage. A running or queued job is always visible
in the list, no matter how many older completed jobs pile up in the same session —
only the most recent finished jobs are kept around (older ones, along with their
temporary audio, are pruned automatically).

Every job has a dismiss button: for a completed job it's a plain ✕ that just
removes it from the list, no confirmation needed. For a running or queued job
it's a red stop icon that asks for confirmation before cancelling — it stops the
Python process and deletes the temporary audio, which cannot be undone.

Completed jobs can be opened with the 📄 button, or sent to a configured
second-brain vault with the 🧠 button (only shown when `secondBrainPath` is set;
see [Setup](#setup)). Opening a transcript prefers Sublime Text if it's
installed; otherwise it prompts you to pick which app to open it with.

Click the output folder name in the footer to open it directly in Finder;
click the pencil icon next to it to change the output folder.

## External Recommendation Trigger

The app registers the `meetingtranscriber://` URL scheme so an external tool
(a calendar watcher, a script, another app) can tell it "this upcoming meeting
is worth recording" without the app knowing anything about calendars itself.
Triggering it shows a native macOS notification with the meeting title and a
short reason — it never starts a recording automatically.

```bash
open "meetingtranscriber://recommend?title=Steering%20Client%20X&reason=external%20client%20%2B%20strategic%20agenda&lead=10"
```

| Param | Description |
| --- | --- |
| `title` | Meeting title, URL-encoded |
| `reason` | Short justification shown in the notification body, URL-encoded |
| `lead` | Minutes-until-start shown in the notification title (default `10`) |

## Processing Queue

Each stopped recording becomes a local transcription job containing the WAV
paths, language, title, track offset, and output directory. Queued jobs do not
block new recordings.

Only one job runs by default to reduce CPU, Metal/GPU, memory, and disk
contention. Increase `maxConcurrentTranscriptions` only after measuring how your
machine behaves with the selected model.

## CLI Usage

```bash
python transcribe_meeting.py \
  --mic mic.wav \
  --system system.wav \
  --out ~/Transcriptions \
  --title "Planning meeting" \
  --format both \
  --model medium \
  --language pt
```

Main options:

| Flag | Description |
| --- | --- |
| `--mic` | Microphone audio track |
| `--system` | System audio track |
| `--out` | Output directory |
| `--title` | Meeting title |
| `--format` | `both` (default), `jsonl`, `markdown`, `llm`, or `analysis` |
| `--persona-analysis` | Writes `.analysis.jsonl` with extra context and quality signals |
| `--language` | `pt` (default), `en`, or `auto` |
| `--backend` | `mlx` (default) or `faster-whisper` |
| `--model` | Whisper model for faster-whisper, from `tiny` to `large-v3` |
| `--sys-offset MS` | System-track offset in milliseconds |
| `--denoise` | Applies stationary-noise reduction to the microphone track |
| `--context-term` | Expected vocabulary sent as hotwords |
| `--hotword` | Proper noun or technical term to reinforce |
| `--replace SOURCE=TARGET` | Deterministic text replacement |
| `--no-default-replacements` | Disables built-in generic replacement rules |
| `--cluster-system-speakers` | Heuristically labels the system track as `Remote_A/B/...` |
| `--speaker-map L=N,...` | Maps speaker labels to names, for example `Remote_A=Alex` |
| `--analysis-context KEY=VALUE` | Metadata for analysis output, for example `org=ExampleCo` |
| `--participant NAME` | Expected participant metadata for analysis output |
| `--filter-suspect` | Omits suspect turns from JSONL |
| `--no-sanitize` | Keeps raw suspect text for debugging |
| `--max-turn-duration SEC` | Maximum consolidated turn duration, default `30` |
| `--no-meta` | Omits the first JSONL metadata record |
| `--no-chunk-overlap` | Disables 3-second overlap for continuous speech chunks |
| `--profile-memory` | Prints RSS per phase to stderr for memory diagnostics (off by default) |

## JSONL Output

Each line is a consolidated turn:

```jsonl
{"speaker":"Você","text":"Esse e um checkpoint que fazemos toda segunda.","start_ms":186000,"end_ms":191200,"confidence":0.94,"is_suspect":false}
{"speaker":"Interlocutor","text":"Talvez valha enviar uma atualizacao para o cliente.","start_ms":414000,"end_ms":419800,"confidence":0.87,"is_suspect":false}
```

`confidence` is derived from `avg_logprob` when the backend exposes it. If no
confidence is available, the value is `-1.0`. `is_suspect` marks low-confidence
turns, likely silence, or structurally unlikely text. Strong silence artifacts,
impossible density, and repetition loops are sanitized to `[inaudível]` by
default; use `--no-sanitize` to inspect raw output.

## Analysis Output

Use `--persona-analysis` when you want richer metadata for later analysis of
tone, role, interaction style, or meeting dynamics.

```bash
python transcribe_meeting.py \
  --mic mic.wav \
  --system system.wav \
  --out ~/Transcriptions \
  --title "Demo conversation" \
  --persona-analysis \
  --analysis-context org=ExampleCo \
  --analysis-context role=facilitator \
  --participant Alex \
  --participant Jordan
```

## Project Structure

```text
meeting-transcriber/
├── transcribe_meeting.py
├── MeetingTranscriber/
│   └── Sources/MeetingTranscriber/
│       ├── MeetingTranscriberApp.swift
│       ├── MenuBarView.swift
│       ├── AppState.swift
│       ├── AppConfig.swift
│       ├── MicRecorder.swift
│       ├── SystemAudioRecorder.swift
│       ├── TranscriptionRunner.swift
│       ├── AudioUtils.swift
│       ├── NotificationManager.swift
│       └── URLSchemeDelegate.swift
└── tests/
```
