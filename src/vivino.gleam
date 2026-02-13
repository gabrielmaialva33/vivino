//// VIVINO - Real-time plant bioelectric monitor
////
//// Reads Arduino serial data directly (no Python needed),
//// processes with viva_tensor + dual AI classifiers,
//// streams live to browser via WebSocket.
////
//// Supports multiple organisms: shimeji, cannabis, generic fungal.
//// Set VIVINO_ORGANISM env var to select (default: shimeji).
////
//// Usage:
////   gleam run                              # auto-detects serial port
////   VIVINO_ORGANISM=cannabis gleam run     # cannabis profile
////   echo "data" | gleam run               # pipe mode (stdin fallback)

import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import vivino/display

@external(erlang, "vivino_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

import vivino/serial/parser
import vivino/serial/port
import vivino/signal/dynamic_gpu
import vivino/signal/features
import vivino/signal/label_bridge
import vivino/signal/learner
import vivino/signal/profile
import vivino/web/pubsub
import vivino/web/server

/// Analysis window size (50 samples @ 20Hz = 2.5s window)
const window_size = 50

/// WebSocket server port
const web_port = 3000

/// Processing state carried through the loop
type LoopState {
  LoopState(
    hdc: learner.DynamicHdcMemory,
    gpu: Result(dynamic_gpu.DynamicGpuClassifier, String),
    profile: profile.OrganismProfile,
    pubsub: process.Subject(pubsub.PubSubMsg),
    buffer: List(parser.Reading),
    sample_count: Int,
  )
}

pub fn main() {
  display.header()

  // 1. Select organism from env var
  let organism =
    get_env("VIVINO_ORGANISM")
    |> result.try(profile.parse_organism)
    |> result.unwrap(profile.Shimeji)
  let prof = profile.get_profile(organism)
  io.println("Organism: " <> prof.display_name <> " [" <> prof.name <> "]")

  // Store organism for label_bridge
  let _ = label_bridge.put_organism(prof.name)

  // 2. Start PubSub actor
  let assert Ok(pubsub_subject) = pubsub.start()
  io.println("PubSub actor started")

  // 3. Start HTTP + WebSocket server
  case server.start(pubsub_subject, web_port) {
    Ok(_) -> Nil
    Error(msg) -> io.println("Warning: " <> msg)
  }

  // 4. Initialize dynamic GPU classifier
  let gpu_state = case dynamic_gpu.init(prof) {
    Ok(g) -> {
      io.println("GPU classifier initialized (" <> prof.name <> " profile)")
      Ok(g)
    }
    Error(e) -> {
      io.println("GPU init failed: " <> e <> " (using HDC fallback)")
      Error(e)
    }
  }

  // 5. Initialize dynamic HDC memory
  let hdc_memory = learner.init(prof)
  io.println("HDC learner ready (10,048 dims, k-NN, auto-calibration 3s)")
  display.separator()

  let state =
    LoopState(
      hdc: hdc_memory,
      gpu: gpu_state,
      profile: prof,
      pubsub: pubsub_subject,
      buffer: [],
      sample_count: 0,
    )

  // 6. Open serial port directly
  case port.auto_open() {
    Ok(serial) -> {
      io.println("Reading from serial port...")
      io.println("")
      serial_loop(state, serial)
    }
    Error(msg) -> {
      io.println("Serial: " <> msg)
      io.println("Falling back to stdin (pipe mode)...")
      io.println("")
      stdin_loop(state)
    }
  }
}

/// Main processing loop: serial port
fn serial_loop(state: LoopState, serial: port.SerialPort) {
  case port.read_port_line(serial) {
    Ok(line) -> {
      let new_state = process_line(line, state)
      serial_loop(new_state, serial)
    }
    Error(_) -> {
      io.println("")
      io.println("Serial port closed.")
      Nil
    }
  }
}

/// Fallback loop: stdin
fn stdin_loop(state: LoopState) {
  case port.read_line() {
    Ok(line) -> {
      let new_state = process_line(line, state)
      stdin_loop(new_state)
    }
    Error(_) -> {
      io.println("")
      io.println("End of input.")
      Nil
    }
  }
}

/// Process a single line: parse -> features -> classify -> learn -> broadcast
fn process_line(line: String, state: LoopState) -> LoopState {
  case parser.parse_line(line) {
    parser.DataLine(reading) -> {
      display.reading(reading)

      // Sliding window
      let trimmed = [reading, ..state.buffer] |> list.take(window_size)
      let buf_len = list.length(trimmed)
      let new_count = state.sample_count + 1

      case buf_len >= 10 {
        True -> {
          let samples = list.reverse(trimmed)
          let feats = features.extract(samples)
          let rule_state =
            features.classify_state_with(feats, state.profile.thresholds)
          display.print_features(feats, rule_state)

          // GPU classification (dynamic)
          let #(gpu_state_str, gpu_sims, new_gpu) = case state.gpu {
            Ok(g) -> {
              let #(s, sims) = dynamic_gpu.classify(g, feats)
              #(s, sims, Ok(g))
            }
            Error(e) -> #("???", [], Error(e))
          }
          display.print_gpu(gpu_sims, gpu_state_str)

          // HDC classification (dynamic k-NN)
          let signal_hv =
            learner.encode(state.hdc, feats, state.profile.quant_ranges)

          // Auto-calibration (first 60 samples → RESTING)
          let hdc_after_cal =
            learner.auto_calibrate(
              state.hdc,
              signal_hv,
              new_count,
              reading.elapsed,
            )

          let #(hdc_state, hdc_sims) =
            learner.classify(hdc_after_cal, signal_hv)
          display.print_hdc_learner(
            hdc_sims,
            learner.state_to_string(hdc_state),
          )
          display.separator()

          // Check for pending labels from dashboard
          let #(final_hdc, final_gpu) = case label_bridge.get_label() {
            Ok(label_str) -> {
              case learner.parse_state(label_str) {
                Ok(label_state) -> {
                  io.println(
                    "  LEARN: labeled as "
                    <> learner.state_to_string(label_state),
                  )
                  let learned_hdc =
                    learner.learn(
                      hdc_after_cal,
                      signal_hv,
                      label_state,
                      reading.elapsed,
                    )
                  let learned_gpu = case new_gpu {
                    Ok(g) -> Ok(dynamic_gpu.learn(g, feats, label_str))
                    Error(e) -> Error(e)
                  }
                  #(learned_hdc, learned_gpu)
                }
                Error(_) -> #(hdc_after_cal, new_gpu)
              }
            }
            Error(_) -> #(hdc_after_cal, new_gpu)
          }

          // Build and broadcast JSON
          let json_str =
            build_json(
              reading,
              feats,
              rule_state,
              gpu_state_str,
              gpu_sims,
              hdc_state,
              hdc_sims,
              state.profile,
              final_hdc,
            )
          process.send(state.pubsub, pubsub.Broadcast(json_str))

          LoopState(
            ..state,
            hdc: final_hdc,
            gpu: final_gpu,
            buffer: trimmed,
            sample_count: new_count,
          )
        }
        False -> {
          let json_str = parser.reading_to_json(reading)
          process.send(state.pubsub, pubsub.Broadcast(json_str))
          LoopState(..state, buffer: trimmed, sample_count: new_count)
        }
      }
    }
    parser.StimLine(stim) -> {
      io.println(
        "STIM: "
        <> stim.protocol
        <> " "
        <> stim.count
        <> " "
        <> stim.stim_type
        <> " "
        <> stim.duration,
      )
      let json_str = parser.stim_to_json(stim)
      process.send(state.pubsub, pubsub.Broadcast(json_str))
      state
    }
    _ -> state
  }
}

/// Build full JSON payload
fn build_json(
  r: parser.Reading,
  f: features.SignalFeatures,
  state: String,
  gpu_state_str: String,
  gpu_sims: List(#(String, Float)),
  hdc_state: learner.PlantState,
  hdc_sims: List(#(learner.PlantState, Float)),
  prof: profile.OrganismProfile,
  hdc_memory: learner.DynamicHdcMemory,
) -> String {
  json.object([
    #("elapsed", json.float(r.elapsed)),
    #("raw", json.int(r.raw)),
    #("mv", json.float(r.mv)),
    #("deviation", json.float(r.deviation)),
    #("state", json.string(state)),
    #("organism", json.string(prof.name)),
    #("organism_display", json.string(prof.display_name)),
    #("gpu_state", json.string(gpu_state_str)),
    #("gpu", dynamic_gpu.results_to_json_value(gpu_sims)),
    #("hdc_state", json.string(learner.state_to_string(hdc_state))),
    #("hdc", learner.similarities_to_json_value(hdc_sims)),
    #("features", features.to_json_value(f)),
    #("learning", learner.learning_to_json_value(hdc_memory)),
  ])
  |> json.to_string
}
