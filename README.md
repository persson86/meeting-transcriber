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

## What's New in 1.5

- The app now asks the pipeline for a review companion,
  `<stem>.analysis.jsonl`, next to the Markdown and JSONL. It carries the track
  of each turn, the quality flags, and one `chunk` record per transcribed block
  (whether the prompt had user terms, coverage retries and whether they were
  adopted, segments dropped at the seam). Text is unchanged. **Send to
  Second Brain** copies it with the other two files.
- The transcript metadata records each track's offset on the session timeline
  (`track_offsets_ms`).
- `review_turns.py` lists flagged turns and plays the right track for a turn:
  see [Reviewing a Transcript](#reviewing-a-transcript).
- The menu footer shows the app version and the pipeline version it will run
  (`v1.5.0 · pipeline 0.9.0`). They can differ: the app runs the pipeline from
  the checkout, so a `git pull` updates it without reinstalling the app.
  (Pipeline 0.9.0.)

## What's New in 1.4.1

- Recording times keep the UTC offset they were recorded with, whatever the
  time zone of the machine that processes them. Only UTC timestamps from older
  versions are converted to local time. (Pipeline 0.8.1.)

## What's New in 1.4

- Re-arming the microphone after an audio route change no longer crashes the
  app: the AVAudioEngine calls that can raise Objective-C exceptions run behind
  an Objective-C shim, so a failed re-arm becomes a partial-capture warning.
  1.3.2 could abort mid-meeting at this point.
- The menu bar icon turns into an orange warning while the microphone is not
  delivering audio during a recording, since notifications are often hidden
  during calls and screen sharing.
- **Usar reunião atual ou próxima do Calendar** picks the meeting in progress
  (or the next one), by the start closest to now. The chosen event's attendees
  (display names only) are written to the transcript metadata as *expected*
  participants. Editing the title drops the association.
- The default title uses the time the recording starts, not the time the
  previous one stopped. Dates are written in local time with the UTC offset, and
  file names use the recording start instead of the processing time.
- `auto` language detects once per track, on the longest speech chunks, and
  then locks it, instead of detecting every 28-second chunk. A Portuguese track
  gets the Portuguese prompt and defaults.
- Whisper prompts now fit a token budget measured with Whisper's own tokenizer,
  ordered so meeting-specific terms survive truncation. An optional local
  vocabulary file (`~/Library/Application Support/MeetingTranscriber/vocabulary.json`,
  never committed) adds names and product terms to the prompt.
- Text replacements only match whole words (`OAT` no longer changes `GOAT`).

## What's New in 1.3

- Durable session manifests and recoverable WAV staging survive app restarts.
- Capture health exposes missing tracks, writer and conversion failures, stream
  interruption, microphone rearm problems, and material timeline gaps.
- Missing callback intervals receive bounded silence so resumed audio keeps its
  original position in the meeting timeline.
- Cancelling or dismissing a job preserves its audio, and failed jobs can be
  retried from the menu.
- Transcript artifacts are written atomically and validated before a job is
  marked successful.
- JSONL keeps the original ASR text when normalization or safety output changes
  what is displayed.
- Portable, integration, model-backed ASR, and release verification gates are
  available through the root `Makefile`.

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
make test-integration  # exercise the Swift to Python process boundary
make test-asr  # run the private, model-backed quality corpus
make verify-release  # portable tests plus a signed app build
```

The app defaults to a source checkout at `~/meeting-transcriber`, with Python at
`.venv/bin/python` and the script at `transcribe_meeting.py`. You can override
paths without recompiling:

```bash
defaults write <bundle-id> projectRoot /path/to/meeting-transcriber
defaults write <bundle-id> pythonPath /path/to/python
defaults write <bundle-id> scriptPath /path/to/transcribe_meeting.py
defaults write <bundle-id> defaultOutputDirectory ~/Transcriptions
defaults write <bundle-id> sessionRoot ~/Library/Application\ Support/MeetingTranscriber/Sessions
defaults write <bundle-id> contextTerms -array "ProjectName" "CustomerName"
defaults write <bundle-id> maxConcurrentTranscriptions 2
defaults write <bundle-id> mlxModel mlx-community/whisper-large-v3-mlx
defaults write <bundle-id> transcriptionBackend mlx
defaults write <bundle-id> debugMemoryLogging -bool YES
defaults write <bundle-id> secondBrainPath /path/to/second-brain
defaults write <bundle-id> vocabularyPath /path/to/vocabulary.json
```

### Vocabulary

Proper nouns (customers, products, colleagues) are the most frequent errors in
meeting transcripts. Create a local file, outside the repository, and the app
passes it to the pipeline when it exists:

```json
{
  "version": 1,
  "terms": ["Acme", "Project Atlas", "Jordan"],
  "replacements": {}
}
```

`terms` are added to the Whisper prompt in priority order within a token budget.
`replacements` are deterministic whole-word corrections: add one only after
checking every occurrence in your existing transcripts, since a wrong global
replacement changes meaning. An invalid file is ignored with a warning, and the
transcription still runs.

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
reinstalls it to `~/Applications/MeetingTranscriber.app`, and reopens it. The
installer refuses to replace a running app so it cannot silently interrupt a
recording; close the app first. Your output folder and settings are untouched.
If you're not sure which folder you
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
**Usar reunião atual ou próxima do Calendar**.

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
3. Enter a meeting title or click **Usar reunião atual ou próxima do Calendar**.
4. Click **Iniciar gravação** to begin recording.
5. Click **Parar e adicionar à fila** to save audio and enqueue the transcription.
6. Follow progress in the **Transcrições** section. JSONL and Markdown files are
   written to the configured output directory.

The Calendar action considers the meeting in progress and the next 24 hours,
and uses the non-cancelled, non-all-day event (shorter than 8 hours) that you
accepted, or that you organized with other participants, whose start is closest
to now. It fills the title field and keeps the event's attendees as expected
participants, but never starts recording automatically. Editing the title after
picking an event drops the association. If no eligible event is found, the
existing title is preserved and the app shows a warning.

To process an iPhone recording manually, click **Processar arquivo de áudio…**. The
file picker opens in Downloads by default; choose the 16 kHz WAV and leave the
app open while the job runs. The app copies the selected file into its durable
session storage and never changes or deletes the original in Downloads. A single imported
track uses the neutral speaker label `Áudio`.

Each recording gets a stable session directory with a durable manifest and WAV
files. After a recording stops, the app returns to the ready state and keeps
processing previous jobs in the background. If the app closes unexpectedly,
recoverable audio remains available and queued jobs return after relaunch.

The wider menu uses native large controls and larger action targets for better
readability. It shows recent jobs as queued, running, cancelling, completed, or
failed. A running job shows a live progress percentage. Active jobs are always
visible. Only the most recent finished jobs remain in the menu; pruning the menu
does not delete their preserved audio or durable manifests.

Every job has a dismiss button. For a completed job it hides the item from the
list without deleting audio. For a running or queued job, the red stop icon asks
for confirmation before cancelling. Cancellation waits for the Python process
to terminate and preserves the input audio. Failed jobs with preserved audio can
be queued again with the retry button.

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

The manifest also records capture integrity. Writer failures, stream termination,
microphone rearm failures, missing tracks, and material duration differences mark
the capture as degraded. The app still transcribes recoverable audio, but the
Markdown and JSONL outputs carry an explicit partial-capture warning instead of
silently presenting the result as complete.

The portable `make test` gate does not load a speech model, request macOS
permissions, use audio hardware, or require the private quality corpus. The
separate `make test-asr` gate fails explicitly when that local corpus is absent;
it is the required semantic check when transcription behavior changes.

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
| `--language` | `pt` (default), `en`, or `auto` (detects once per track and locks it) |
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
| `--participant NAME` | Expected participant (e.g. calendar invitee) written to the metadata |
| `--participant-prompt` | Also adds participants to the Whisper prompt (experimental) |
| `--vocabulary JSON` | Local vocabulary file (`terms`, `replacements`) |
| `--calendar-title`, `--calendar-start`, `--calendar-end`, `--calendar-organizer` | Calendar event metadata |
| `--no-title-prompt` | Do not add the meeting title to the Whisper prompt |
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

Use `--persona-analysis` (analysis JSONL only, no Markdown) when you want richer metadata for later analysis of
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

To keep the Markdown and JSONL and add the analysis file, use `--with-analysis`
instead (the app does this).

## Reviewing a Transcript

`review_turns.py` finds a turn and plays that part of the right track. It
takes the `.md`, `.jsonl` or `.analysis.jsonl` (it prefers the companion) and
only needs the system `python3`.

```bash
python3 review_turns.py meeting.md                    # flagged turns
python3 review_turns.py meeting.md --at 48:10          # play the turn shown as [48:10]
python3 review_turns.py meeting.md --at 48:10 --track system
python3 review_turns.py meeting.md --range 48:05-48:30 --track system
python3 review_turns.py meeting.md --chunks --at 48:10 # how that block was transcribed
```

Audio comes from the app session (`Sessions/<session_id>/`), the archived
folder next to the transcript, or `--audio-dir`. Clips go to
`~/Library/Caches/MeetingTranscriber/clips/`. Without audio it exits with code
3 and says nothing was checked against the recording. The listing leaves out
`remote_unclustered`, which marks every remote turn when speakers are not split;
an empty list does not mean the transcript is right.

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
