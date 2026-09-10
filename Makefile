PYTHON = .venv/bin/python

.PHONY: test test-python test-swift test-integration test-asr verify-release baselines baselines-update app setup install

setup:
	python3 -m venv .venv
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r requirements.txt

install:
	./install.sh

# Gate portátil: não usa modelo, permissões, hardware ou corpus privado.
test: test-python test-swift

test-python:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest tests/ -q -p no:cacheprovider

test-swift:
	SDKROOT="$$(xcrun --sdk macosx --show-sdk-path)" swift test --package-path MeetingTranscriber

test-integration:
	SDKROOT="$$(xcrun --sdk macosx --show-sdk-path)" swift test --package-path MeetingTranscriber --filter TranscriptionRunnerTests

test-asr:
	@test -f tests/fixtures/audio-baselines/manifest.json || { \
		echo "BLOQUEADO: corpus local ausente; nenhum teste ASR foi executado." >&2; exit 2; \
	}
	$(PYTHON) tests/run_quality_baselines.py

verify-release: test app

# Regressão de qualidade completa: transcreve os casos primary-regression
# e compara contra os goldens aprovados (pesado — Whisper large-v3)
baselines:
	$(PYTHON) tests/run_quality_baselines.py

baselines-update:
	$(PYTHON) tests/run_quality_baselines.py --update-golden

app:
	$(MAKE) -C MeetingTranscriber build
