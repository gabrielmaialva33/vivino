//// Vision detector types and JSON parsing.
////
//// Receives YOLO detection results from the Python sidecar and
//// provides typed access to detections, motion, and frame metadata.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result

/// A single object detection from YOLO
pub type Detection {
  Detection(
    class: String,
    confidence: Float,
    bbox: #(Int, Int, Int, Int),
    area: Int,
  )
}

/// A complete frame result from the vision sidecar
pub type VisionFrame {
  VisionFrame(
    timestamp_ms: Int,
    fps: Float,
    detections: List(Detection),
    motion: Float,
    frame_number: Int,
    inference_ms: Float,
  )
}

/// Check if any person is detected in the frame
pub fn has_person(frame: VisionFrame) -> Bool {
  list.any(frame.detections, fn(d) { d.class == "person" })
}

/// Check if significant motion is detected
pub fn has_motion(frame: VisionFrame, threshold: Float) -> Bool {
  frame.motion >. threshold
}

/// Count detections of a specific class
pub fn count_class(frame: VisionFrame, class: String) -> Int {
  list.filter(frame.detections, fn(d) { d.class == class })
  |> list.length
}

/// Parse a JSON line from the vision sidecar into a VisionFrame.
/// Returns Error if the JSON is a status/error message (not a detection frame).
pub fn parse_vision_json(json_str: String) -> Result(VisionFrame, Nil) {
  let decoder = {
    use ts <- decode.field("ts", decode.int)
    use fps <- decode.field("fps", decode.float)
    use detections <- decode.field(
      "detections",
      decode.list(detection_decoder()),
    )
    use motion <- decode.field("motion", decode.float)
    use frame <- decode.field("frame", decode.int)
    use inference_ms <- decode.field("inference_ms", decode.float)
    decode.success(VisionFrame(
      timestamp_ms: ts,
      fps:,
      detections:,
      motion:,
      frame_number: frame,
      inference_ms:,
    ))
  }
  json.parse(json_str, decoder)
  |> result.replace_error(Nil)
}

/// Decoder for a single Detection
fn detection_decoder() -> decode.Decoder(Detection) {
  use class <- decode.field("class", decode.string)
  use conf <- decode.field("conf", decode.float)
  use bbox_list <- decode.field("bbox", decode.list(decode.int))
  use area <- decode.field("area", decode.int)
  let bbox = case bbox_list {
    [x1, y1, x2, y2] -> #(x1, y1, x2, y2)
    _ -> #(0, 0, 0, 0)
  }
  decode.success(Detection(class:, confidence: conf, bbox:, area:))
}

/// Encode a VisionFrame to JSON string for broadcasting to dashboard
pub fn vision_to_json(frame: VisionFrame) -> String {
  let det_json =
    list.map(frame.detections, fn(d) {
      json.object([
        #("class", json.string(d.class)),
        #("conf", json.float(d.confidence)),
        #(
          "bbox",
          json.array([d.bbox.0, d.bbox.1, d.bbox.2, d.bbox.3], json.int),
        ),
        #("area", json.int(d.area)),
      ])
    })

  json.object([
    #("type", json.string("vision")),
    #("ts", json.int(frame.timestamp_ms)),
    #("fps", json.float(frame.fps)),
    #("motion", json.float(frame.motion)),
    #("frame", json.int(frame.frame_number)),
    #("inference_ms", json.float(frame.inference_ms)),
    #("detections", json.preprocessed_array(det_json)),
    #("person", json.bool(has_person(frame))),
    #("detection_count", json.int(list.length(frame.detections))),
  ])
  |> json.to_string
}

/// Format detection summary for terminal display
pub fn detection_summary(frame: VisionFrame) -> String {
  let count = list.length(frame.detections)
  let person_count = count_class(frame, "person")
  "Vision: "
  <> int.to_string(count)
  <> " det, "
  <> int.to_string(person_count)
  <> " person, motion="
  <> float.to_string(frame.motion)
  <> ", "
  <> float.to_string(frame.inference_ms)
  <> "ms"
}
