//// Parser for Arduino CSV serial output.
////
//// The Arduino sends: "elapsed,raw,mv,deviation\n"
//// Also handles METER, EVENT, and STATS lines.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// A single parsed reading from Arduino serial
pub type Reading {
  Reading(elapsed: Float, raw: Int, mv: Float, deviation: Float)
}

/// A METER reading (oversampled 14-bit)
pub type MeterReading {
  MeterReading(elapsed: Float, mv: Float, volts: Float)
}

/// An event detected by Arduino
pub type Event {
  Event(id: Int, kind: String, peak_mv: Float, duration_ms: Int)
}

/// A stimulus event from the stimulus generator
pub type Stimulus {
  Stimulus(
    elapsed: Float,
    protocol: String,
    count: String,
    stim_type: String,
    duration: String,
  )
}

/// All possible line types from Arduino
pub type Line {
  DataLine(Reading)
  MeterLine(MeterReading)
  EventLine(Event)
  StimLine(Stimulus)
  StatsLine(String)
  HeaderLine(String)
}

/// Parse a number as float (accepts both "1.5" and "42")
fn parse_number(s: String) -> Result(Float, Nil) {
  case float.parse(s) {
    Ok(f) -> Ok(f)
    Error(_) ->
      case int.parse(s) {
        Ok(i) -> Ok(int.to_float(i))
        Error(_) -> Error(Nil)
      }
  }
}

/// Parse a single CSV line: "5.02,156,1510.26,-97.83" or "5.02,156,973,-84"
pub fn parse_reading(line: String) -> Result(Reading, Nil) {
  let trimmed = string.trim(line)
  let parts = string.split(trimmed, ",")
  case parts {
    [elapsed_s, raw_s, mv_s, dev_s] -> {
      use elapsed <- result.try(parse_number(elapsed_s))
      use raw <- result.try(int.parse(raw_s))
      use mv <- result.try(parse_number(mv_s))
      use dev <- result.try(parse_number(dev_s))
      Ok(Reading(elapsed:, raw:, mv:, deviation: dev))
    }
    _ -> Error(Nil)
  }
}

/// Parse any line from Arduino output
pub fn parse_line(line: String) -> Line {
  let trimmed = string.trim(line)
  case trimmed {
    "STIM," <> rest -> parse_stim(rest)
    "METER," <> rest -> parse_meter(rest)
    ">>>" <> _ -> parse_event(trimmed)
    "---" <> _ -> StatsLine(trimmed)
    _ ->
      case parse_reading(trimmed) {
        Ok(r) -> DataLine(r)
        Error(_) -> HeaderLine(trimmed)
      }
  }
}

/// Parse STIM line: "5.02,HABIT,3/12,PULSE,50ms" or "5.02,EXPLORE,2,BURST,5x10ms"
fn parse_stim(rest: String) -> Line {
  let parts = string.split(rest, ",")
  case parts {
    [elapsed_s, protocol, count, stim_type, duration] -> {
      let elapsed = parse_number(elapsed_s) |> result.unwrap(0.0)
      StimLine(Stimulus(elapsed:, protocol:, count:, stim_type:, duration:))
    }
    _ -> HeaderLine("STIM," <> rest)
  }
}

/// Convert a Stimulus to JSON string
pub fn stim_to_json(s: Stimulus) -> String {
  json.object([
    #("type", json.string("stim")),
    #("elapsed", json.float(s.elapsed)),
    #("protocol", json.string(s.protocol)),
    #("count", json.string(s.count)),
    #("stim_type", json.string(s.stim_type)),
    #("duration", json.string(s.duration)),
  ])
  |> json.to_string
}

/// Parse METER line: "METER,5.23,1512.340,14bit,1.5123"
fn parse_meter(rest: String) -> Line {
  let parts = string.split(rest, ",")
  case parts {
    [elapsed_s, mv_s, _14bit, volts_s] -> {
      let elapsed = float.parse(elapsed_s) |> result.unwrap(0.0)
      let mv = float.parse(mv_s) |> result.unwrap(0.0)
      let volts = float.parse(volts_s) |> result.unwrap(0.0)
      MeterLine(MeterReading(elapsed:, mv:, volts:))
    }
    _ -> HeaderLine("METER," <> rest)
  }
}

/// Parse EVENT line (simplified - events are mainly for display)
fn parse_event(_line: String) -> Line {
  EventLine(Event(id: 0, kind: "VP", peak_mv: 0.0, duration_ms: 0))
}

/// Parse multiple lines, returning only valid readings
pub fn parse_readings(text: String) -> List(Reading) {
  text
  |> string.split("\n")
  |> list.filter_map(parse_reading)
}

/// Convert a Reading to JSON string
pub fn reading_to_json(r: Reading) -> String {
  json.object([
    #("elapsed", json.float(r.elapsed)),
    #("raw", json.int(r.raw)),
    #("mv", json.float(r.mv)),
    #("deviation", json.float(r.deviation)),
  ])
  |> json.to_string
}
