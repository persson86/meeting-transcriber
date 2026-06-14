PYTHON = .venv/bin/python

.PHONY: test baselines baselines-update app setup install

setup:
	python3 -m venv .venv
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r requirements.txt

install:
	./install.sh

# Gate local: unit + validação de fixtures/goldens (rápido, sem transcrever)
test:
	$(PYTHON) -m pytest tests/ -q

# Regressão de qualidade completa: transcreve os casos primary-regression
# e compara contra os goldens aprovados (pesado — Whisper large-v3)
baselines:
	$(PYTHON) tests/run_quality_baselines.py

baselines-update:
	$(PYTHON) tests/run_quality_baselines.py --update-golden

app:
	$(MAKE) -C MeetingTranscriber build
