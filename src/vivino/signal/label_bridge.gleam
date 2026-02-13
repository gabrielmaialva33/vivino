//// Label bridge for inter-process communication.
////
//// Uses Erlang persistent_term for O(1) communication between
//// WebSocket handlers (label commands) and the main processing loop.

/// Store a pending label (called from WebSocket handler)
@external(erlang, "vivino_ffi", "put_label")
pub fn put_label(label: String) -> Result(Nil, Nil)

/// Read and consume a pending label (called from main loop)
@external(erlang, "vivino_ffi", "get_label")
pub fn get_label() -> Result(String, Nil)

/// Set the active organism
@external(erlang, "vivino_ffi", "put_organism")
pub fn put_organism(organism: String) -> Result(Nil, Nil)

/// Get the active organism
@external(erlang, "vivino_ffi", "get_organism")
pub fn get_organism() -> Result(String, Nil)
