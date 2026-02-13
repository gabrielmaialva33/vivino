# Vivino

Real-time plant bioelectric signal processor written in [Gleam](https://gleam.run) (Erlang/BEAM target).

Reads 14-bit ADC data from Arduino + AD620 amplifier on fungal mycelium (*Hypsizygus tessellatus* — shimeji), extracts 27 signal features, classifies states with dual AI classifiers, and streams live to a web dashboard via WebSocket.

## Quick Start

```bash
gleam deps download
gleam run              # auto-detects Arduino on /dev/ttyUSB*
```

Dashboard at `http://localhost:3000`

## Architecture

```
Arduino (AD620 + 14-bit ADC)
    │ serial 115200
    ▼
Gleam/BEAM (Erlang port FFI)
    │
    ├── Parser (CSV → Reading)
    ├── Sliding Window (50 samples, 2.5s)
    ├── Feature Extraction (27-dim vector)
    │     ├── Time-domain (11)
    │     ├── Hjorth parameters (3)
    │     ├── MFCC via Goertzel (8)
    │     └── Spectral (5)
    ├── GPU Classifier (euclidean distance, 6 states)
    ├── HDC Classifier (10,048-dim hypervectors, 5 states)
    │
    └── WebSocket broadcast → Browser Dashboard
```

## Dependencies

- [Gleam](https://gleam.run) >= 1.14.0
- OTP >= 28
- [viva_tensor](https://github.com/mrootx/viva_tensor) (local path dependency)
- Arduino with AD620 instrumentation amplifier

## Development

```bash
gleam build               # compile (zero warnings expected)
gleam test                # run tests
gleam format src test     # auto-format
```
