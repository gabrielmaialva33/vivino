//// Text-to-speech for the robozin via espeak-ng.

@external(erlang, "vivino_ffi", "speak")
pub fn speak(text: String) -> Nil

pub fn greet() -> Nil {
  speak("Oi! Eu sou o robozin. Estou acordando meus olhos.")
}

pub fn person_detected() -> Nil {
  speak("Epa! Detectei uma pessoa!")
}

pub fn person_returned() -> Nil {
  speak("Olha só, alguém voltou!")
}

pub fn person_gone() -> Nil {
  speak("A pessoa foi embora.")
}

pub fn plant_detected() -> Nil {
  speak("Detectei uma planta. Será o shimeji?")
}

pub fn watching() -> Nil {
  speak("Ainda estou de olho.")
}

pub fn vision_online() -> Nil {
  speak("Visão online. Câmera conectada.")
}
