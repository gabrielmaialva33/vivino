# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Vivino** is a real-time plant bioelectric signal processor written in **Gleam** (Erlang/BEAM target). It reads 14-bit ADC data from Arduino sensors on fungal mycelium (*Hypsizygus tessellatus* — shimeji), extracts 27 signal features, classifies plant states with dual AI classifiers (GPU euclidean distance + HDC hyperdimensional computing), and streams results live to a web dashboard via WebSocket.

## Build & Development Commands

```bash
gleam deps download       # Fetch dependencies (requires local viva_tensor — see below)
gleam build               # Compile (must produce zero warnings)
gleam test                # Run gleeunit tests
gleam run                 # Start server — auto-detects Arduino serial port, falls back to stdin
gleam format --check src test  # Check formatting (CI enforces this)
gleam format src test     # Auto-format code
```

**Dashboard:** `http://localhost:3000` — WebSocket on `/ws`

## Serial Port

Gleam reads the Arduino directly via Erlang `open_port` FFI — no Python needed.

- Auto-detects `/dev/ttyUSB*` and `/dev/ttyACM*`
- Falls back to stdin pipe if no Arduino found
- Baud rate: 115200, raw mode, `-hupcl` (no DTR reset)

## Critical Dependency

`viva_tensor` is a **local path dependency** at `/home/gabriel-maia/Documentos/viva_tensor`. It provides tensor operations, MFCC, HDC hypervectors, and NF4 quantization. Without it, nothing compiles.

## Architecture

**Data flow:** Arduino serial → `serial/port` (Erlang port FFI) → `serial/parser` → sliding window (50 samples) → `signal/features` (27-dim vector) → dual classifiers → JSON broadcast via `web/pubsub` → WebSocket clients

### Core Modules

| Module | Role |
|--------|------|
| `vivino.gleam` | Main loop: auto-opens serial, maintains sliding window, orchestrates feature extraction + classification |
| `vivino_ffi.erl` | Erlang FFI — `open_port`/`read_port_line` for serial, `stty` config, `write_serial`, monotonic time |
| `serial/parser.gleam` | Parses CSV lines: `elapsed,raw,mv,deviation` |
| `serial/port.gleam` | Serial port abstraction: auto-detect, open, read, write |
| `signal/features.gleam` | Extracts 27 features: time-domain, Hjorth, MFCC (8 coefficients via Goertzel), spectral entropy |
| `signal/gpu.gleam` | Euclidean distance classifier — 6 states (RESTING/CALM/ACTIVE/TRANSITION/STIMULUS/STRESS), softmax T=0.08, 19 features |
| `signal/hdc.gleam` | HDC classifier — 10,048-dim hypervectors, role-binding, cosine similarity, 5 states |
| `web/server.gleam` | Mist HTTP + WebSocket server, **dashboard HTML is embedded inline** (~500 lines of HTML/JS) |
| `web/pubsub.gleam` | OTP actor — manages WebSocket subscriptions, broadcasts JSON to all clients |
| `storage.gleam` | NF4 compression for session persistence |
| `display.gleam` | Terminal UI formatting |

### Key Patterns

- **Immutable, pure-functional**: no mutable state anywhere; sliding window via `[new, ..buffer] |> list.take(50)`
- **OTP actors**: PubSub is a `gleam/otp/actor` managing subscription lifecycle
- **Dual classifier fallback**: GPU (primary) degrades gracefully if init fails; HDC runs independently
- **Erlang FFI**: all system I/O (serial, time) goes through `vivino_ffi.erl`
- **Code in English, dashboard UI in pt-BR**

## Arduino Input Format

CSV at 20 Hz: `elapsed_ms,raw_adc,millivolts,deviation\n` — 14-bit ADC (256x oversampling), 0.305 mV/LSB resolution.

## CI

GitHub Actions (`.github/workflows/test.yml`): runs `gleam test` + `gleam format --check` on OTP 28 / Gleam 1.14.0.
