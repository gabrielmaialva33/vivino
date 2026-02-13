//// Vision processing loop — runs alongside the main bioelectric signal loop.
////
//// Spawns Python YOLO sidecar as an Erlang port, reads JSON detection
//// results, and broadcasts them to all WebSocket clients via PubSub.
//// Crash-isolated: if the vision sidecar dies, plant monitoring continues.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/io
import vivino/vision/detector
import vivino/web/pubsub

/// Opaque Erlang port reference
pub type VisionPort =
  Dynamic

/// FFI bindings — same pattern as serial port
@external(erlang, "vivino_ffi", "open_vision")
fn open_vision(
  rtsp_url: String,
  model_path: String,
  conf: Float,
) -> Result(VisionPort, Dynamic)

@external(erlang, "vivino_ffi", "read_vision_line")
fn read_vision_line(port: VisionPort) -> Result(String, Dynamic)

@external(erlang, "vivino_ffi", "vision_cmd")
pub fn vision_cmd(port: VisionPort, cmd: String) -> Result(Nil, Dynamic)

/// Configuration for the vision sidecar
pub type VisionConfig {
  VisionConfig(rtsp_url: String, model_path: String, confidence: Float)
}

/// Default configuration for the Yoosee camera
pub fn default_config(camera_ip: String) -> VisionConfig {
  VisionConfig(
    rtsp_url: "rtsp://" <> camera_ip <> ":554/onvif1",
    model_path: "yolo11s.pt",
    confidence: 0.35,
  )
}

/// Start the vision detector loop in the current process.
/// Typically called from a spawned BEAM process.
pub fn run(config: VisionConfig, pubsub: Subject(pubsub.PubSubMsg)) -> Nil {
  io.println("Vision: connecting to " <> config.rtsp_url)
  case open_vision(config.rtsp_url, config.model_path, config.confidence) {
    Ok(port) -> {
      io.println("Vision: sidecar started, waiting for GPU warmup...")
      vision_loop(port, pubsub, config, 0)
    }
    Error(_) -> {
      io.println("Vision: failed to start sidecar, retrying in 10s...")
      process.sleep(10_000)
      run(config, pubsub)
    }
  }
}

/// Main vision read loop
fn vision_loop(
  port: VisionPort,
  pubsub: Subject(pubsub.PubSubMsg),
  config: VisionConfig,
  frame_count: Int,
) -> Nil {
  case read_vision_line(port) {
    Ok(json_line) -> {
      case detector.parse_vision_json(json_line) {
        Ok(frame) -> {
          // Broadcast vision data to all WebSocket clients
          let json = detector.vision_to_json(frame)
          process.send(pubsub, pubsub.Broadcast(json))

          // Log person detection
          case detector.has_person(frame) {
            True ->
              io.println(
                "  PERSON DETECTED (frame "
                <> detector.detection_summary(frame)
                <> ")",
              )
            False -> Nil
          }
        }
        Error(_) -> {
          // Status messages, errors — log but continue
          io.println("Vision: " <> json_line)
        }
      }
      vision_loop(port, pubsub, config, frame_count + 1)
    }
    Error(_) -> {
      io.println("Vision: sidecar disconnected, restarting in 5s...")
      process.sleep(5000)
      run(config, pubsub)
    }
  }
}
