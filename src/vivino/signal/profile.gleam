//// Organism profiles for multi-species bioelectric classification.
////
//// Each profile defines calibrated parameters for a specific organism:
//// quantization ranges (HDC), normalization bounds (GPU),
//// prototype vectors (GPU), and classification thresholds.

import gleam/string
import vivino/signal/features.{
  type FeatureThresholds, type QualityThresholds, FeatureThresholds,
  QualityThresholds,
}

/// Supported organisms
pub type Organism {
  Shimeji
  Cannabis
  FungalGeneric
}

/// HDC quantization ranges (5 features)
pub type QuantRanges {
  QuantRanges(
    mean_min: Float,
    mean_max: Float,
    std_min: Float,
    std_max: Float,
    range_min: Float,
    range_max: Float,
    slope_min: Float,
    slope_max: Float,
    energy_min: Float,
    energy_max: Float,
  )
}

/// Complete organism profile
pub type OrganismProfile {
  OrganismProfile(
    organism: Organism,
    name: String,
    display_name: String,
    quant_ranges: QuantRanges,
    gpu_bounds: List(#(Float, Float)),
    thresholds: FeatureThresholds,
    gpu_prototypes: List(List(Float)),
    softmax_temp: Float,
    quality_thresholds: QualityThresholds,
  )
}

/// Get profile for an organism
pub fn get_profile(organism: Organism) -> OrganismProfile {
  case organism {
    Shimeji -> shimeji_profile()
    Cannabis -> cannabis_profile()
    FungalGeneric -> fungal_generic_profile()
  }
}

/// Parse organism from string
pub fn parse_organism(s: String) -> Result(Organism, Nil) {
  case string.lowercase(s) {
    "shimeji" -> Ok(Shimeji)
    "cannabis" -> Ok(Cannabis)
    "fungal" | "fungal_generic" | "fungo" -> Ok(FungalGeneric)
    _ -> Error(Nil)
  }
}

/// Organism to string identifier
pub fn organism_to_string(organism: Organism) -> String {
  case organism {
    Shimeji -> "shimeji"
    Cannabis -> "cannabis"
    FungalGeneric -> "fungal_generic"
  }
}

/// Organism display name
pub fn organism_display_name(organism: Organism) -> String {
  case organism {
    Shimeji -> "H. tessellatus (shimeji)"
    Cannabis -> "Cannabis sativa"
    FungalGeneric -> "Fungo generico"
  }
}

// ============================================================
// Shimeji profile (existing calibrated values)
// ============================================================

fn shimeji_profile() -> OrganismProfile {
  OrganismProfile(
    organism: Shimeji,
    name: "shimeji",
    display_name: "H. tessellatus (shimeji)",
    // Tighter quant_ranges for better HDC quantization resolution
    // Calibrated from 10h real data (696K samples, 2026-02-13)
    quant_ranges: QuantRanges(
      mean_min: -15.0,
      mean_max: 15.0,
      std_min: 0.0,
      std_max: 20.0,
      range_min: 0.0,
      range_max: 60.0,
      slope_min: -15.0,
      slope_max: 15.0,
      energy_min: 0.0,
      energy_max: 20_000.0,
    ),
    gpu_bounds: [
      #(-50.0, 50.0),
      #(0.0, 50.0),
      #(-80.0, 100.0),
      #(-80.0, 150.0),
      #(0.0, 200.0),
      #(-30.0, 30.0),
      #(0.0, 150_000.0),
      #(0.0, 50.0),
      #(0.0, 800.0),
      #(0.0, 1.0),
      #(0.0, 3.0),
      #(0.0, 6.0),
      #(-3.0, 3.0),
      #(-2.0, 8.0),
      #(0.0, 1.0),
      #(0.0, 20.0),
      #(-1.0, 1.0),
      #(-50.0, 50.0),
      #(-50.0, 50.0),
    ],
    thresholds: FeatureThresholds(
      resting_std_max: 3.0,
      resting_range_max: 15.0,
      calm_std_max: 8.0,
      active_std_min: 8.0,
      agitated_std_min: 25.0,
      strong_range_min: 120.0,
      spike_dvdt_min: 500.0,
      spike_range_min: 60.0,
      transition_slope_min: 8.0,
      transition_std_min: 6.0,
    ),
    gpu_prototypes: shimeji_prototypes(),
    softmax_temp: 0.12,
    // Autocorrelation-based noise: fungi have high temporal structure
    quality_thresholds: QualityThresholds(
      flat_std_min: 0.01,
      saturated_range_max: 240.0,
      artifact_kurtosis_max: 20.0,
      noisy_autocorr_min: 0.15,
    ),
  )
}

/// Shimeji GPU prototypes — recalibrated from 10h real data (2026-02-13)
/// RESTING calibrated from 696K samples: mean=0.1, std=1.7, range=7.7
/// Other states proportionally spaced (Adamatzky 2022 spike amplitudes)
/// Order: RESTING, CALM, ACTIVE, TRANSITION, STIMULUS, STRESS
fn shimeji_prototypes() -> List(List(Float)) {
  [
    // RESTING: σ~1.7mV (real 10h data: median std=1.7, range=7.7, peaks=8.6)
    [
      0.1, 1.7, -5.0, 6.0, 7.7, 0.0, 150.0, 1.8, 68.0, 0.1, 0.35, 2.2, 0.4, 0.0,
      0.7, 8.5, 0.85, -1.1, 1.1,
    ],
    // CALM: σ~4mV (2.3x RESTING, slow oscillation increase)
    [
      0.5, 4.0, -8.0, 12.0, 20.0, 1.5, 900.0, 4.5, 120.0, 0.12, 0.45, 2.0, 0.5,
      0.5, 0.65, 7.0, 0.78, -3.0, 5.0,
    ],
    // ACTIVE: σ~10mV, spike trains 0.5-2Hz (Adamatzky 2018)
    [
      2.0, 10.0, -20.0, 30.0, 50.0, 4.0, 5500.0, 11.0, 250.0, 0.2, 0.7, 1.8, 0.3,
      1.0, 0.55, 10.0, 0.6, -6.0, 10.0,
    ],
    // TRANSITION: propagating signal with directional slope
    [
      3.0, 7.0, -12.0, 22.0, 34.0, -8.0, 2800.0, 8.0, 170.0, 0.15, 0.55, 2.5,
      -0.5, 1.5, 0.6, 7.0, 0.7, -4.0, 8.0,
    ],
    // STIMULUS: fast dV/dt, sharp peak (0.03-2.1mV spike amplitude)
    [
      8.0, 20.0, -35.0, 60.0, 95.0, 15.0, 25_000.0, 22.0, 500.0, 0.25, 1.0, 2.8,
      1.5, 4.0, 0.45, 3.0, 0.4, -15.0, 25.0,
    ],
    // STRESS: high σ, chaotic spiking (sustained agitation)
    [
      12.0, 35.0, -50.0, 100.0, 150.0, 8.0, 70_000.0, 38.0, 400.0, 0.3, 1.3, 3.5,
      0.5, 2.5, 0.75, 8.0, 0.3, -25.0, 40.0,
    ],
  ]
}

// ============================================================
// Cannabis sativa profile
// ============================================================

fn cannabis_profile() -> OrganismProfile {
  OrganismProfile(
    organism: Cannabis,
    name: "cannabis",
    display_name: "Cannabis sativa",
    quant_ranges: QuantRanges(
      mean_min: -200.0,
      mean_max: 200.0,
      std_min: 0.0,
      std_max: 150.0,
      range_min: 0.0,
      range_max: 600.0,
      slope_min: -100.0,
      slope_max: 100.0,
      energy_min: 0.0,
      energy_max: 2_000_000.0,
    ),
    gpu_bounds: [
      #(-200.0, 200.0),
      #(0.0, 150.0),
      #(-300.0, 300.0),
      #(-300.0, 500.0),
      #(0.0, 600.0),
      #(-100.0, 100.0),
      #(0.0, 2_000_000.0),
      #(0.0, 150.0),
      #(0.0, 3000.0),
      #(0.0, 1.0),
      #(0.0, 5.0),
      #(0.0, 8.0),
      #(-3.0, 3.0),
      #(-2.0, 10.0),
      #(0.0, 1.0),
      #(0.0, 30.0),
      #(-1.0, 1.0),
      #(-200.0, 200.0),
      #(-200.0, 200.0),
    ],
    thresholds: FeatureThresholds(
      resting_std_max: 10.0,
      resting_range_max: 50.0,
      calm_std_max: 25.0,
      active_std_min: 25.0,
      agitated_std_min: 70.0,
      strong_range_min: 400.0,
      spike_dvdt_min: 1500.0,
      spike_range_min: 200.0,
      transition_slope_min: 25.0,
      transition_std_min: 15.0,
    ),
    gpu_prototypes: cannabis_prototypes(),
    softmax_temp: 0.08,
    // Vascular plants: wider ranges, higher signal amplitude
    quality_thresholds: QualityThresholds(
      flat_std_min: 0.1,
      saturated_range_max: 2000.0,
      artifact_kurtosis_max: 15.0,
      noisy_autocorr_min: 0.15,
    ),
  )
}

/// Cannabis GPU prototypes — literature-based estimates
/// Vascular plant with larger action potentials (Volkov et al.)
fn cannabis_prototypes() -> List(List(Float)) {
  [
    // RESTING: σ~15mV, quiet vascular tissue
    [
      5.0, 15.0, -25.0, 40.0, 65.0, 1.0, 12_000.0, 16.0, 180.0, 0.1, 0.4, 2.0,
      0.8, 1.5, 0.7, 3.0, 0.88, -5.0, 12.0,
    ],
    // CALM: σ~25mV, slow oscillations
    [
      10.0, 25.0, -50.0, 80.0, 130.0, 5.0, 35_000.0, 27.0, 350.0, 0.15, 0.55,
      1.8, 0.4, 0.8, 0.65, 5.0, 0.75, -15.0, 25.0,
    ],
    // ACTIVE: σ~50mV, propagating APs
    [
      15.0, 50.0, -100.0, 160.0, 260.0, 15.0, 150_000.0, 52.0, 900.0, 0.25, 0.9,
      1.6, 0.3, 1.2, 0.55, 8.0, 0.55, -35.0, 50.0,
    ],
    // TRANSITION: directional propagation
    [
      25.0, 35.0, -60.0, 120.0, 180.0, -40.0, 70_000.0, 38.0, 600.0, 0.2, 0.7,
      2.3, -0.5, 1.8, 0.6, 6.0, 0.65, -20.0, 40.0,
    ],
    // STIMULUS: fast AP response (50-150mV)
    [
      40.0, 80.0, -120.0, 250.0, 370.0, 60.0, 400_000.0, 85.0, 2000.0, 0.3, 1.4,
      2.5, 1.5, 5.0, 0.4, 4.0, 0.35, -60.0, 100.0,
    ],
    // STRESS: sustained high amplitude
    [
      60.0, 120.0, -180.0, 380.0, 560.0, 25.0, 1_200_000.0, 130.0, 1500.0, 0.35,
      1.8, 3.2, 0.5, 3.0, 0.75, 10.0, 0.25, -90.0, 150.0,
    ],
  ]
}

// ============================================================
// Generic fungal profile (wider ranges)
// ============================================================

fn fungal_generic_profile() -> OrganismProfile {
  OrganismProfile(
    organism: FungalGeneric,
    name: "fungal_generic",
    display_name: "Fungo generico",
    quant_ranges: QuantRanges(
      mean_min: -100.0,
      mean_max: 100.0,
      std_min: 0.0,
      std_max: 80.0,
      range_min: 0.0,
      range_max: 400.0,
      slope_min: -50.0,
      slope_max: 50.0,
      energy_min: 0.0,
      energy_max: 500_000.0,
    ),
    gpu_bounds: [
      #(-100.0, 100.0),
      #(0.0, 80.0),
      #(-150.0, 150.0),
      #(-150.0, 250.0),
      #(0.0, 400.0),
      #(-50.0, 50.0),
      #(0.0, 500_000.0),
      #(0.0, 80.0),
      #(0.0, 1500.0),
      #(0.0, 1.0),
      #(0.0, 4.0),
      #(0.0, 7.0),
      #(-3.0, 3.0),
      #(-2.0, 9.0),
      #(0.0, 1.0),
      #(0.0, 25.0),
      #(-1.0, 1.0),
      #(-100.0, 100.0),
      #(-100.0, 100.0),
    ],
    thresholds: FeatureThresholds(
      resting_std_max: 5.0,
      resting_range_max: 25.0,
      calm_std_max: 12.0,
      active_std_min: 12.0,
      agitated_std_min: 40.0,
      strong_range_min: 200.0,
      spike_dvdt_min: 800.0,
      spike_range_min: 100.0,
      transition_slope_min: 12.0,
      transition_std_min: 8.0,
    ),
    gpu_prototypes: fungal_generic_prototypes(),
    softmax_temp: 0.08,
    // Generic fungal: moderate ranges between shimeji and cannabis
    quality_thresholds: QualityThresholds(
      flat_std_min: 0.05,
      saturated_range_max: 800.0,
      artifact_kurtosis_max: 18.0,
      noisy_autocorr_min: 0.15,
    ),
  )
}

/// Generic fungal prototypes — wider ranges than shimeji
fn fungal_generic_prototypes() -> List(List(Float)) {
  [
    // RESTING: σ~8mV
    [
      3.0, 8.0, -15.0, 25.0, 40.0, 0.5, 3500.0, 9.0, 100.0, 0.1, 0.4, 2.1, 0.9,
      1.8, 0.7, 4.0, 0.89, -3.0, 7.0,
    ],
    // CALM: σ~12mV
    [
      5.0, 12.0, -25.0, 40.0, 65.0, 3.0, 8000.0, 13.0, 180.0, 0.15, 0.5, 1.9,
      0.5, 0.7, 0.65, 6.0, 0.78, -7.0, 12.0,
    ],
    // ACTIVE: σ~25mV, spike trains
    [
      8.0, 25.0, -50.0, 80.0, 130.0, 8.0, 35_000.0, 27.0, 500.0, 0.25, 0.8, 1.7,
      0.3, 1.1, 0.55, 10.0, 0.58, -18.0, 25.0,
    ],
    // TRANSITION: propagating signal
    [
      12.0, 18.0, -35.0, 60.0, 95.0, -18.0, 18_000.0, 20.0, 350.0, 0.2, 0.6, 2.4,
      -0.5, 1.6, 0.6, 7.0, 0.68, -10.0, 20.0,
    ],
    // STIMULUS: spike response
    [
      25.0, 45.0, -70.0, 130.0, 200.0, 30.0, 120_000.0, 48.0, 1000.0, 0.3, 1.3,
      2.7, 1.5, 4.5, 0.45, 3.0, 0.38, -35.0, 55.0,
    ],
    // STRESS: sustained agitation
    [
      35.0, 65.0, -100.0, 190.0, 290.0, 12.0, 300_000.0, 70.0, 800.0, 0.35, 1.6,
      3.3, 0.5, 2.8, 0.75, 9.0, 0.28, -50.0, 80.0,
    ],
  ]
}
