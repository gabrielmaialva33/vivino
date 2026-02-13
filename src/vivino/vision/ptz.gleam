//// PTZ camera control via RTSP SET_PARAMETER.
////
//// Controls Yoosee camera pan/tilt using the RTSP protocol.
//// Note: The firmware uses "DWON" (typo) instead of "DOWN".

import gleam/dynamic.{type Dynamic}

@external(erlang, "vivino_ffi", "ptz_move")
fn ffi_ptz_move(ip: String, direction: String) -> Result(Nil, Dynamic)

/// PTZ movement directions
pub type PtzDirection {
  Up
  Down
  Left
  Right
  Stop
}

/// Move the camera in a direction.
/// Connects via RTSP SET_PARAMETER on port 554.
pub fn move(ip: String, dir: PtzDirection) -> Result(Nil, Dynamic) {
  let cmd = case dir {
    Up -> "UP"
    Down -> "DWON"
    Left -> "LEFT"
    Right -> "RIGHT"
    Stop -> "STOP"
  }
  ffi_ptz_move(ip, cmd)
}

/// Parse a direction string from WebSocket commands.
pub fn parse_direction(dir: String) -> Result(PtzDirection, Nil) {
  case dir {
    "UP" -> Ok(Up)
    "DOWN" -> Ok(Down)
    "LEFT" -> Ok(Left)
    "RIGHT" -> Ok(Right)
    "STOP" -> Ok(Stop)
    _ -> Error(Nil)
  }
}
