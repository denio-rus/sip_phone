#!/usr/bin/env bash
# Запуск SIP-телефона одной командой: ./run.sh
set -e
cd "$(dirname "$0")"
mix deps.get
mix run --no-halt
