//// VIVINO - Real-time plant bioelectric monitor
////
//// Reads Arduino serial data directly (no Python needed),
//// processes with viva_tensor + GPU CUDA,
//// streams live to browser via WebSocket.
////
//// Usage:
////   gleam run                    # auto-detects serial port
////   echo "data" | gleam run     # pipe mode (stdin fallback)

import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import vivino/display
import vivino/serial/parser
import vivino/serial/port
import vivino/signal/features
import vivino/signal/gpu
import vivino/signal/hdc
import vivino/web/pubsub
import vivino/web/server

/// Analysis window size (50 samples @ 20Hz = 2.5s window)
const window_size = 50

/// WebSocket server port
const web_port = 3000

pub fn main() {
  display.header()

  // 1. Start PubSub actor
  let assert Ok(pubsub_subject) = pubsub.start()
  io.println("PubSub actor started")

  // 2. Start HTTP + WebSocket server
  case server.start(pubsub_subject, web_port) {
    Ok(_) -> Nil
    Error(msg) -> io.println("Warning: " <> msg)
  }

  // 3. Initialize GPU classifier
  let gpu_state = case gpu.init() {
    Ok(g) -> {
      io.println("GPU classifier initialized (CUDA RTX 4090)")
      Ok(g)
    }
    Error(e) -> {
      io.println("GPU init failed: " <> e <> " (using HDC fallback)")
      Error(e)
    }
  }

  // 4. Initialize HDC memory
  let memory = hdc.init()
  io.println("HDC fallback ready (10,048 dims)")
  display.separator()

  // 5. Open serial port directly (no Python needed)
  case port.auto_open() {
    Ok(serial) -> {
      io.println("Reading from serial port...")
      io.println("")
      serial_loop(memory, gpu_state, pubsub_subject, [], serial)
    }
    Error(msg) -> {
      io.println("Serial: " <> msg)
      io.println("Falling back to stdin (pipe mode)...")
      io.println("")
      stdin_loop(memory, gpu_state, pubsub_subject, [])
    }
  }
}

/// Main processing loop: serial port -> parse -> features -> classify -> broadcast
fn serial_loop(
  memory: hdc.HdcMemory,
  gpu_state: Result(gpu.GpuClassifier, String),
  pubsub_subject: process.Subject(pubsub.PubSubMsg),
  buffer: List(parser.Reading),
  serial: port.SerialPort,
) {
  case port.read_port_line(serial) {
    Ok(line) -> {
      let #(new_buffer, new_memory) =
        process_line(line, memory, gpu_state, pubsub_subject, buffer)
      serial_loop(new_memory, gpu_state, pubsub_subject, new_buffer, serial)
    }
    Error(_) -> {
      io.println("")
      io.println("Serial port closed.")
      Nil
    }
  }
}

/// Fallback loop: stdin -> parse -> features -> classify -> broadcast
fn stdin_loop(
  memory: hdc.HdcMemory,
  gpu_state: Result(gpu.GpuClassifier, String),
  pubsub_subject: process.Subject(pubsub.PubSubMsg),
  buffer: List(parser.Reading),
) {
  case port.read_line() {
    Ok(line) -> {
      let #(new_buffer, new_memory) =
        process_line(line, memory, gpu_state, pubsub_subject, buffer)
      stdin_loop(new_memory, gpu_state, pubsub_subject, new_buffer)
    }
    Error(_) -> {
      io.println("")
      io.println("End of input.")
      Nil
    }
  }
}

/// Process a single line: parse -> features -> classify -> broadcast
fn process_line(
  line: String,
  memory: hdc.HdcMemory,
  gpu_state: Result(gpu.GpuClassifier, String),
  pubsub_subject: process.Subject(pubsub.PubSubMsg),
  buffer: List(parser.Reading),
) -> #(List(parser.Reading), hdc.HdcMemory) {
  case parser.parse_line(line) {
    parser.DataLine(reading) -> {
      display.reading(reading)

      // Sliding window: O(1) prepend + O(K) take
      let trimmed = [reading, ..buffer] |> list.take(window_size)
      let buf_len = list.length(trimmed)

      case buf_len >= 10 {
        True -> {
          let samples = list.reverse(trimmed)
          let feats = features.extract(samples)
          let state = features.classify_state(feats)
          display.print_features(feats, state)

          // GPU classification (primary)
          let #(gpu_state_str, gpu_sims) = case gpu_state {
            Ok(g) -> gpu.classify(g, feats)
            Error(_) -> #("???", [])
          }
          display.print_gpu(gpu_sims, gpu_state_str)

          // HDC classification (secondary/fallback)
          let signal_hv = hdc.encode(memory, feats)
          let hdc_state = hdc.classify(memory, signal_hv)
          let hdc_sims = hdc.similarities(memory, signal_hv)
          display.print_hdc(hdc_sims, hdc.state_to_string(hdc_state))
          display.separator()

          // JSON with both classifiers
          let json_str =
            build_json(
              reading,
              feats,
              state,
              gpu_state_str,
              gpu_sims,
              hdc_state,
              hdc_sims,
            )
          process.send(pubsub_subject, pubsub.Broadcast(json_str))

          #(trimmed, memory)
        }
        False -> {
          let json_str = parser.reading_to_json(reading)
          process.send(pubsub_subject, pubsub.Broadcast(json_str))
          #(trimmed, memory)
        }
      }
    }
    parser.StimLine(stim) -> {
      io.println(
        "⚡ STIM: "
        <> stim.protocol
        <> " "
        <> stim.count
        <> " "
        <> stim.stim_type
        <> " "
        <> stim.duration,
      )
      let json_str = parser.stim_to_json(stim)
      process.send(pubsub_subject, pubsub.Broadcast(json_str))
      #(buffer, memory)
    }
    _ -> {
      #(buffer, memory)
    }
  }
}

/// Build full JSON payload with reading + features + GPU + HDC
fn build_json(
  r: parser.Reading,
  f: features.SignalFeatures,
  state: String,
  gpu_state_str: String,
  gpu_sims: List(#(String, Float)),
  hdc_state: hdc.PlantState,
  hdc_sims: List(#(hdc.PlantState, Float)),
) -> String {
  json.object([
    #("elapsed", json.float(r.elapsed)),
    #("raw", json.int(r.raw)),
    #("mv", json.float(r.mv)),
    #("deviation", json.float(r.deviation)),
    #("state", json.string(state)),
    #("gpu_state", json.string(gpu_state_str)),
    #("gpu", gpu.results_to_json_value(gpu_sims)),
    #("hdc_state", json.string(hdc.state_to_string(hdc_state))),
    #("hdc", hdc.similarities_to_json_value(hdc_sims)),
    #("features", features.to_json_value(f)),
  ])
  |> json.to_string
}
