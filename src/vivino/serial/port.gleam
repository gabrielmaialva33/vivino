//// Serial port reader via Erlang port.
////
//// Opens /dev/ttyUSBx directly through Erlang's port system
//// for minimum latency reading. Auto-detects port. No Python needed.

import gleam/io
import vivino/serial/parser.{type Reading}

/// Messages from serial port reader
pub type SerialMsg {
  NewReading(Reading)
  RawLine(String)
  SerialError(String)
  SerialClosed
}

/// Erlang port reference
pub type SerialPort

/// Auto-detect Arduino serial port
@external(erlang, "vivino_ffi", "detect_port")
pub fn detect_port() -> Result(String, Nil)

/// Open serial port and return Erlang port reference
@external(erlang, "vivino_ffi", "open_serial")
pub fn open(device: String, baud: Int) -> Result(SerialPort, Nil)

/// Read a line from an Erlang port (serial device)
@external(erlang, "vivino_ffi", "read_port_line")
pub fn read_port_line(port: SerialPort) -> Result(String, Nil)

/// Read a line from stdin (for pipe mode fallback)
@external(erlang, "vivino_ffi", "read_line")
pub fn read_line() -> Result(String, Nil)

/// Monotonic timestamp in milliseconds (for latency measurement)
@external(erlang, "vivino_ffi", "timestamp_ms")
pub fn timestamp_ms() -> Int

/// Send a command to Arduino via serial port
@external(erlang, "vivino_ffi", "send_serial_cmd")
pub fn send_command(cmd: String) -> Result(Nil, Nil)

/// Detect and open Arduino serial port automatically
pub fn auto_open() -> Result(SerialPort, String) {
  case detect_port() {
    Ok(device) -> {
      io.println("Serial detected: " <> device)
      case open(device, 115_200) {
        Ok(p) -> {
          io.println("Serial opened: " <> device <> " @ 115200")
          Ok(p)
        }
        Error(_) -> Error("Failed to open " <> device)
      }
    }
    Error(_) -> Error("No Arduino found on /dev/ttyUSB* or /dev/ttyACM*")
  }
}
