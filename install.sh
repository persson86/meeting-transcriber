#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${MEETING_TRANSCRIBER_REPO_URL:-https://github.com/persson86/meeting-transcriber.git}"
BUNDLE_ID="io.github.meetingtranscriber.app"
APP_PATH="$HOME/Applications/MeetingTranscriber.app"

INSTALL_ROOT="$(pwd)"
PROJECT_DIR="${MEETING_TRANSCRIBER_PROJECT_DIR:-$INSTALL_ROOT/meeting-transcriber}"
OUTPUT_DIR="${MEETING_TRANSCRIBER_OUTPUT_DIR:-$INSTALL_ROOT/transcriptions}"
IN_PLACE=0

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Meeting Transcriber requires macOS 13 or newer." >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command git
require_command make
require_command python3
require_command swift
require_command defaults

if [[ -f "$INSTALL_ROOT/transcribe_meeting.py" && -d "$INSTALL_ROOT/MeetingTranscriber" ]]; then
  PROJECT_DIR="$INSTALL_ROOT"
  IN_PLACE=1
fi

if [[ -d "$PROJECT_DIR/.git" ]]; then
  if [[ "$IN_PLACE" == "1" ]]; then
    echo "Using local checkout: $PROJECT_DIR"
  else
    echo "Updating existing checkout: $PROJECT_DIR"
    git -C "$PROJECT_DIR" pull --ff-only
  fi
elif [[ -e "$PROJECT_DIR" ]]; then
  echo "Install path exists but is not a git checkout: $PROJECT_DIR" >&2
  echo "Remove it or set MEETING_TRANSCRIBER_PROJECT_DIR to another path." >&2
  exit 1
else
  echo "Cloning Meeting Transcriber into: $PROJECT_DIR"
  git clone "$REPO_URL" "$PROJECT_DIR"
fi

mkdir -p "$OUTPUT_DIR"

cd "$PROJECT_DIR"

echo "Installing Python dependencies..."
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.txt

echo "Building and installing macOS app..."
OPEN_APP=0 make -C MeetingTranscriber install

defaults write "$BUNDLE_ID" projectRoot "$PROJECT_DIR"
defaults write "$BUNDLE_ID" pythonPath "$PROJECT_DIR/.venv/bin/python"
defaults write "$BUNDLE_ID" scriptPath "$PROJECT_DIR/transcribe_meeting.py"
defaults write "$BUNDLE_ID" defaultOutputDirectory "$OUTPUT_DIR"
defaults delete "$BUNDLE_ID" outputDirectory >/dev/null 2>&1 || true

open "$APP_PATH"

cat <<EOF

Meeting Transcriber installed.
App: $APP_PATH
Project: $PROJECT_DIR
Transcriptions: $OUTPUT_DIR

On first launch, grant Microphone and Screen & System Audio Recording permissions.
EOF
