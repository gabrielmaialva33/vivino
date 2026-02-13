// ============================================
// SENTIR TUDO — Fungal Bioelectric Monitor v8
// "Ouvindo o Cogumelo" — High Resolution Edition
// ATmega328P bare-metal optimized
// AD620 + configurable 14/15-bit oversampling
// ============================================
// Target: Hypsizygus tessellatus (shimeji)
// Signal band: 0.1-5 Hz (Adamatzky 2022)
// v8: Full raw pipeline — sub-mV precision
// Output: CSV with 0.1mV resolution
// ============================================
// OUTPUTS:
//   D2  = Stimulus output (10kΩ → needle)
//   D9  = Speaker R — Drone/breathing (Timer1 CTC)
//   D8  = Speaker L — Spike clicks (software)
//   D3  = Fan PWM   — Activity wind (Timer2 OC2B)
//   D4  = LED Red    — Negative deviation
//   D7  = LED Green  — Positive deviation
// ============================================

#include <avr/sleep.h>
#include <avr/power.h>

// ═══════════════════════════════════════════
// PIN MAPPING — Direct port manipulation
// ═══════════════════════════════════════════
// D2  = PD2 = Stimulus output (10kΩ → needle)
// D3  = PD3 = Fan PWM (Timer2 OC2B)
// D4  = PD4 = LED Red
// D7  = PD7 = LED Green
// D8  = PB0 = Speaker L (clicks, software toggle)
// D9  = PB1 = Speaker R (drone, Timer1 OC1A)
// A0  = PC0 = ADC input (AD620 VOUT)

#define STIM_HIGH()   (PORTD |= (1 << PD2))
#define STIM_LOW()    (PORTD &= ~(1 << PD2))

#define LED_G_ON()    (PORTD |= (1 << PD7))
#define LED_G_OFF()   (PORTD &= ~(1 << PD7))
#define LED_R_ON()    (PORTD |= (1 << PD4))
#define LED_R_OFF()   (PORTD &= ~(1 << PD4))
#define LED_BOTH_ON() (PORTD |= (1 << PD7) | (1 << PD4))
#define LED_BOTH_OFF()(PORTD &= ~((1 << PD7) | (1 << PD4)))

#define SPK_L_HIGH()  (PORTB |= (1 << PB0))
#define SPK_L_LOW()   (PORTB &= ~(1 << PB0))

// ═══════════════════════════════════════════
// OVERSAMPLING CONFIG (AVR121 App Note)
// ═══════════════════════════════════════════
// Set OVERSAMPLE_BITS to desired effective resolution:
//   14 = 256x  oversample, 67µV/LSB, ~37 raw/s, 20Hz output
//   15 = 1024x oversample, 33µV/LSB, ~9 raw/s,  9Hz output
//   16 = 4096x oversample, 17µV/LSB, ~2.3 raw/s, 2Hz output
//
// For fungi (0.1-5Hz band): 15-bit @ 9Hz is Nyquist-optimal
// ═══════════════════════════════════════════
#define OVERSAMPLE_BITS  14

#define OVERSAMPLE_EXTRA (OVERSAMPLE_BITS - 10)
#define OVERSAMPLE_N     (1L << (2 * OVERSAMPLE_EXTRA))
#define OVERSAMPLE_SHIFT OVERSAMPLE_EXTRA

// ADC reference = 1.1V internal
// Resolution = 1100mV / 2^OVERSAMPLE_BITS
#if OVERSAMPLE_BITS == 15
  #define PRINT_INTERVAL 110   // ~9Hz (1024x takes ~107ms)
  #define RESOLUTION_UV  34    // 33.6 µV/LSB
#elif OVERSAMPLE_BITS == 16
  #define PRINT_INTERVAL 450   // ~2Hz (4096x takes ~427ms)
  #define RESOLUTION_UV  17    // 16.8 µV/LSB
#else
  #define PRINT_INTERVAL 50    // 20Hz (256x takes ~27ms)
  #define RESOLUTION_UV  67    // 67.1 µV/LSB
#endif

// ═══════════════════════════════════════════
// RAW ↔ mV CONVERSION MACROS
// All signal processing uses raw ADC units.
// Conversion to mV happens ONLY at serial output.
// ═══════════════════════════════════════════
#define MV_TO_RAW(mv)   ((int16_t)(((int32_t)(mv) << OVERSAMPLE_BITS) / 1100))
#define RAW_TO_FLOAT_MV(raw) ((float)(raw) * (1100.0f / (float)(1L << OVERSAMPLE_BITS)))

volatile uint32_t adc_accum = 0;
volatile uint16_t adc_os_count = 0;
volatile uint16_t adc_result = 0;
volatile bool adc_ready = false;

// ═══════════════════════════════════════════
// FILTER — 5pt circular MA (O(1) per sample)
// Operates in raw ADC units (NOT mV)
// ═══════════════════════════════════════════
#define FILTER_SIZE 5
int16_t filter_buf[FILTER_SIZE];
uint8_t filter_idx = 0;
int32_t filter_sum = 0;
bool filter_full = false;

// ═══════════════════════════════════════════
// DUAL-SPEED ADAPTIVE BASELINE (raw units)
// ═══════════════════════════════════════════
int32_t baseline_fp = 0;
bool baseline_set = false;
unsigned long baseline_start;
#define BASELINE_TIME 5000
#define BASE_FAST_SHIFT  6
#define BASE_SLOW_SHIFT  12
#define BASE_SWITCH_RAW  MV_TO_RAW(5)

int32_t cal_baseline_fp = 0;

// ═══════════════════════════════════════════
// NOISE FLOOR + EVENT DETECTION (raw units)
// ═══════════════════════════════════════════
int32_t noise_floor_fp = (int32_t)MV_TO_RAW(10) << 8;
#define NOISE_ALPHA_SHIFT 5
#define MIN_THRESHOLD_RAW  MV_TO_RAW(3)
#define MAX_THRESHOLD_RAW  MV_TO_RAW(200)
#define NOISE_MULT 3
#define DELTA_THRESHOLD_RAW MV_TO_RAW(2)

int16_t sig_min = 32767, sig_max = 0;
int32_t sig_sum = 0;
uint32_t sig_count = 0;

int16_t prev_raw = 0;
int16_t peak_val_raw = 0;
bool in_event = false;
unsigned long event_start = 0;
uint16_t event_count = 0;
char event_type = ' ';

int8_t trend_up = 0, trend_down = 0;

// ═══════════════════════════════════════════
// TIMING
// ═══════════════════════════════════════════
unsigned long start_time;
unsigned long last_print = 0;
unsigned long last_stats = 0;
#define STATS_INTERVAL 10000

// ═══════════════════════════════════════════
// STIMULUS — protocols on D2
// ═══════════════════════════════════════════
volatile uint8_t stim_protocol = 0;  // 0=OFF 1=HABIT 2=EXPLORE 3=SINGLE
uint8_t stim_count = 0;
uint8_t stim_total = 0;
unsigned long stim_interval = 30000;
unsigned long last_stim_time = 0;
unsigned long stim_start_ms = 0;
bool stim_active = false;
const uint8_t EXPLORE_TYPES = 5;
uint8_t explore_idx = 0;

// ═══════════════════════════════════════════
// MULTI-SENSORY CONTROLS
// ═══════════════════════════════════════════
bool audio_on = true;     // speakers ON by default
bool fan_on = true;       // fan ON by default
bool drone_on = true;     // drone continuous
bool clicks_on = true;    // spike clicks

// ═══════════════════════════════════════════
// DRONE — Timer1 CTC on D9 (OC1A)
// Frequency = F_CPU / (2 * prescaler * (1+OCR1A))
// Prescaler=64: freq = 125000 / (1+OCR1A)
// ═══════════════════════════════════════════
#define DRONE_BASE_HZ   220   // A3 at baseline
#define DRONE_MIN_HZ     55   // A1 (2 octaves down)
#define DRONE_MAX_HZ   1760   // A6 (3 octaves up)

// ═══════════════════════════════════════════
// FAN — Timer2 OC2B PWM on D3
// Activity EMA → 0-255 duty cycle
// ═══════════════════════════════════════════
uint16_t fan_activity_fp = 0;  // fixed-point <<8
#define FAN_ALPHA_SHIFT 4      // α=1/16, smooth transitions

// ═══════════════════════════════════════════
// CLICK — short beep on spike detection
// ═══════════════════════════════════════════
#define CLICK_FREQ_HZ   2500  // sharp click
#define CLICK_DUR_MS     12   // short burst
#define EVENT_BEEP_HZ   800   // longer event tone
#define EVENT_BEEP_MS    30

// ═══════════════════════════════════════════
// SERIAL OUTPUT BUFFER
// ═══════════════════════════════════════════
char tx_buf[96];

// ═══════════════════════════════════════════
// FORMAT HELPER — raw to mV string "123.4"
// Uses fixed-point: deciMv = (raw * 11000) >> bits
// No float in signal path, float only here at print
// ═══════════════════════════════════════════
static uint8_t format_mv(char* buf, int16_t raw_val) {
  int32_t deci = ((int32_t)raw_val * 11000L) >> OVERSAMPLE_BITS;
  char* p = buf;
  if (deci < 0) { *p++ = '-'; deci = -deci; }
  int16_t whole = (int16_t)(deci / 10);
  uint8_t frac = (uint8_t)(deci % 10);
  int len = sprintf(p, "%d.%d", whole, frac);
  return (uint8_t)(len + (p - buf));
}

// ═══════════════════════════════════════════
// ADC SETUP — Maximum precision
// ═══════════════════════════════════════════
void setup_adc() {
  cli();
  DIDR0 = (1 << ADC0D);
  ADMUX = (1 << REFS1) | (1 << REFS0) | 0;
  ADCSRA = (1 << ADEN)  | (1 << ADSC)  | (1 << ADATE) |
           (1 << ADIE)  | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
  ADCSRB = 0;
  sei();
}

// ═══════════════════════════════════════════
// ADC ISR — N-sample accumulator → M-bit
// ═══════════════════════════════════════════
ISR(ADC_vect) {
  uint8_t low = ADCL;
  uint8_t high = ADCH;
  uint16_t sample = (high << 8) | low;
  adc_accum += sample;
  adc_os_count++;
  if (adc_os_count >= OVERSAMPLE_N) {
    adc_result = (uint16_t)(adc_accum >> OVERSAMPLE_SHIFT);
    adc_ready = true;
    adc_accum = 0;
    adc_os_count = 0;
  }
}

// ═══════════════════════════════════════════
// 5pt MOVING AVERAGE — O(1), raw units
// ═══════════════════════════════════════════
static inline int16_t apply_filter(int16_t new_raw) {
  filter_sum -= filter_buf[filter_idx];
  filter_sum += new_raw;
  filter_buf[filter_idx] = new_raw;
  if (++filter_idx >= FILTER_SIZE) {
    filter_idx = 0;
    filter_full = true;
  }
  uint8_t count = filter_full ? FILTER_SIZE : filter_idx;
  return (int16_t)(filter_sum / count);
}

// ═══════════════════════════════════════════
// DUAL-SPEED BASELINE (raw units)
// ═══════════════════════════════════════════
static inline int16_t update_baseline(int16_t raw, int16_t abs_dev) {
  uint8_t shift = (abs_dev < BASE_SWITCH_RAW) ? BASE_FAST_SHIFT : BASE_SLOW_SHIFT;
  baseline_fp = baseline_fp - (baseline_fp >> shift)
              + ((int32_t)raw << (12 - shift));
  return (int16_t)(baseline_fp >> 12);
}

// ═══════════════════════════════════════════
// DRONE SETUP — Timer1 CTC, toggle OC1A (D9)
// ═══════════════════════════════════════════
void setup_drone() {
  PRR &= ~(1 << PRTIM1);  // re-enable Timer1
  TCCR1A = (1 << COM1A0); // toggle OC1A on compare match
  TCCR1B = (1 << WGM12) | (1 << CS11) | (1 << CS10); // CTC, /64
  OCR1A = 567;             // ~220Hz (A3)
  DDRB |= (1 << PB1);     // D9 output
}

void set_drone_freq(uint16_t freq_hz) {
  if (!audio_on || !drone_on || freq_hz < DRONE_MIN_HZ) {
    TCCR1A &= ~(1 << COM1A0); // mute: disconnect OC1A
    return;
  }
  freq_hz = constrain(freq_hz, DRONE_MIN_HZ, DRONE_MAX_HZ);
  TCCR1A |= (1 << COM1A0);  // enable output
  OCR1A = (125000UL / freq_hz) - 1;
}

void mute_drone() {
  TCCR1A &= ~(1 << COM1A0);
}

// ═══════════════════════════════════════════
// FAN SETUP — Timer2 Fast PWM, OC2B (D3)
// ~976Hz PWM, smooth and quiet for DC fan
// ═══════════════════════════════════════════
void setup_fan() {
  TCCR2A = (1 << COM2B1) | (1 << WGM21) | (1 << WGM20);
  TCCR2B = (1 << CS22);   // prescaler /64 → ~976Hz
  OCR2B = 0;               // start off
  DDRD |= (1 << PD3);     // D3 output
}

void set_fan_speed(uint8_t speed) {
  OCR2B = fan_on ? speed : 0;
}

// ═══════════════════════════════════════════
// CLICK SOUND — software toggle on D8
// Blocking but very short (12-30ms)
// ═══════════════════════════════════════════
void click_sound(uint16_t freq_hz, uint8_t dur_ms) {
  if (!audio_on || !clicks_on) return;
  uint16_t half_period = 500000UL / freq_hz;
  uint16_t cycles = (uint32_t)freq_hz * dur_ms / 1000;
  for (uint16_t i = 0; i < cycles; i++) {
    SPK_L_HIGH();
    delayMicroseconds(half_period);
    SPK_L_LOW();
    delayMicroseconds(half_period);
  }
}

// ═══════════════════════════════════════════
// STIMULUS FUNCTIONS — D2 (PD2) via 10kΩ
// Adamatzky 2018: fungi respond to 5-60s thermal
// Electrical: low freq (1-100mHz) in P. ostreatus
// ═══════════════════════════════════════════
void stim_pulse(uint8_t dur_ms) {
  STIM_HIGH();
  delay(dur_ms);
  STIM_LOW();
  Serial.print(F("STIM,"));
  Serial.println(dur_ms);
}

void stim_burst(uint8_t n, uint8_t dur_ms, uint8_t gap_ms) {
  for (uint8_t i = 0; i < n; i++) {
    STIM_HIGH();
    delay(dur_ms);
    STIM_LOW();
    if (i < n - 1) delay(gap_ms);
  }
  Serial.print(F("STIM_BURST,"));
  Serial.print(n);
  Serial.print(',');
  Serial.println(dur_ms);
}

void stim_ramp(uint8_t steps, uint8_t start_ms, uint8_t end_ms) {
  for (uint8_t i = 0; i < steps; i++) {
    uint8_t d = start_ms + (uint16_t)(end_ms - start_ms) * i / (steps - 1);
    STIM_HIGH();
    delay(d);
    STIM_LOW();
    delay(100);
  }
  Serial.print(F("STIM_RAMP,"));
  Serial.print(steps);
  Serial.print(',');
  Serial.print(start_ms);
  Serial.print('-');
  Serial.println(end_ms);
}

void execute_stimulus() {
  if (stim_protocol == 0) return;
  unsigned long now = millis();
  if (now - last_stim_time < stim_interval) return;
  last_stim_time = now;

  switch (stim_protocol) {
    case 1: // HABIT — single pulse, repeated
      stim_pulse(50);
      break;
    case 2: // EXPLORE — cycle through patterns
      switch (explore_idx % EXPLORE_TYPES) {
        case 0: stim_pulse(20);  break;  // short
        case 1: stim_pulse(100); break;  // long
        case 2: stim_burst(3, 30, 50);  break;  // triplet
        case 3: stim_burst(5, 20, 80);  break;  // burst
        case 4: stim_ramp(5, 10, 100);  break;  // ramp
      }
      explore_idx++;
      break;
    case 3: // SINGLE — one shot
      stim_pulse(50);
      stim_protocol = 0;
      Serial.println(F("STIM_DONE"));
      return;
    case 4: // FAST — rapid habituation
      stim_pulse(50);
      break;
  }

  stim_count++;
  if (stim_count >= stim_total && stim_total > 0) {
    stim_protocol = 0;
    Serial.println(F("STIM_COMPLETE"));
  }
}

// ═══════════════════════════════════════════
// SERIAL COMMAND HANDLER
// A=Audio V=Fan D=Drone C=Clicks
// H=Habit E=Explore S=Single F=Fast Q=Quit
// ═══════════════════════════════════════════
void check_serial_commands() {
  if (!Serial.available()) return;

  char cmd = Serial.read();
  switch (cmd) {
    case 'A':
      audio_on = !audio_on;
      if (!audio_on) mute_drone();
      Serial.println(audio_on ? F("AUDIO_ON") : F("AUDIO_OFF"));
      break;

    case 'V':
      fan_on = !fan_on;
      if (!fan_on) set_fan_speed(0);
      Serial.println(fan_on ? F("FAN_ON") : F("FAN_OFF"));
      break;

    case 'D':
      drone_on = !drone_on;
      if (!drone_on) mute_drone();
      Serial.println(drone_on ? F("DRONE_ON") : F("DRONE_OFF"));
      break;

    case 'C':
      clicks_on = !clicks_on;
      Serial.println(clicks_on ? F("CLICKS_ON") : F("CLICKS_OFF"));
      break;

    case 'X':
      // Kill all outputs + stop stimulus
      audio_on = false;
      fan_on = false;
      stim_protocol = 0;
      STIM_LOW();
      mute_drone();
      set_fan_speed(0);
      Serial.println(F("ALL_OFF"));
      break;

    case 'O':
      // All on
      audio_on = true;
      fan_on = true;
      drone_on = true;
      clicks_on = true;
      Serial.println(F("ALL_ON"));
      break;

    // ─── Stimulus protocols ───
    case 'H':  // Habituation: 12 pulses @ 30s
      stim_protocol = 1; stim_count = 0;
      stim_total = 12; stim_interval = 30000;
      last_stim_time = millis() - stim_interval; // fire immediately
      Serial.println(F("STIM_HABIT_12x30s"));
      break;
    case 'E':  // Explore: 10 pulses @ 45s, 5 patterns
      stim_protocol = 2; stim_count = 0;
      stim_total = 10; stim_interval = 45000;
      explore_idx = 0;
      last_stim_time = millis() - stim_interval;
      Serial.println(F("STIM_EXPLORE_10x45s"));
      break;
    case 'S':  // Single pulse
      stim_protocol = 3; stim_count = 0;
      stim_total = 1; stim_interval = 0;
      last_stim_time = 0;
      Serial.println(F("STIM_SINGLE"));
      break;
    case 'F':  // Fast: 20 pulses @ 15s
      stim_protocol = 4; stim_count = 0;
      stim_total = 20; stim_interval = 15000;
      last_stim_time = millis() - stim_interval;
      Serial.println(F("STIM_FAST_20x15s"));
      break;
    case 'Q':  // Quit stimulus
      stim_protocol = 0;
      STIM_LOW();
      Serial.println(F("STIM_STOP"));
      break;
  }
  while (Serial.available()) Serial.read();
}

// ═══════════════════════════════════════════
// SETUP
// ═══════════════════════════════════════════
void setup() {
  Serial.begin(115200);

  // Port setup
  DDRD |= (1 << PD2) | (1 << PD3) | (1 << PD4) | (1 << PD7); // D2,D3,D4,D7 output
  PORTD &= ~(1 << PD2);  // stimulus LOW
  DDRB |= (1 << PB0) | (1 << PB1);               // D8,D9 output

  // Power reduction: only disable SPI and TWI
  // Keep: Timer0 (millis), Timer1 (drone), Timer2 (fan), USART0, ADC
  PRR = (1 << PRSPI) | (1 << PRTWI);

  // Initialize peripherals
  setup_drone();
  setup_fan();

  for (uint8_t i = 0; i < FILTER_SIZE; i++) filter_buf[i] = 0;

  start_time = millis();
  baseline_start = millis();

  Serial.println(F(""));
  Serial.println(F("========================================"));
  Serial.println(F("  SENTIR TUDO v8 — High Resolution"));
  Serial.print(F("  AD620 → A0 | "));
  Serial.print(OVERSAMPLE_BITS);
  Serial.print(F("-bit | "));
  Serial.print(RESOLUTION_UV);
  Serial.println(F("uV/LSB"));
  Serial.print(F("  Oversample: "));
  Serial.print(OVERSAMPLE_N);
  Serial.print(F("x | Output: "));
  Serial.print(1000 / PRINT_INTERVAL);
  Serial.println(F("Hz"));
  Serial.println(F("  Pipeline: full raw (sub-mV precision)"));
  Serial.println(F("  Speaker L=Clicks  R=Drone  Fan=D3"));
  Serial.println(F("========================================"));
  Serial.println(F("A=Audio V=Fan D=Drone C=Clicks X=Off O=On"));
  Serial.println(F("H=Habit E=Explore S=Single F=Fast Q=Quit"));
  Serial.println(F("Calibrating baseline (5s)..."));

  LED_BOTH_ON();
  setup_adc();
}

// ═══════════════════════════════════════════
// MAIN LOOP — Full raw pipeline
// All processing in ADC units, convert to mV
// only at CSV output for sub-mV precision.
// ═══════════════════════════════════════════
void loop() {
  if (!adc_ready) return;
  adc_ready = false;

  unsigned long now = millis();

  uint16_t raw = adc_result;
  int16_t filtered = apply_filter((int16_t)raw);

  // ─── Calibration phase (raw units) ───
  if (!baseline_set) {
    if (cal_baseline_fp == 0) {
      cal_baseline_fp = (int32_t)filtered << 4;
    } else {
      cal_baseline_fp = cal_baseline_fp - (cal_baseline_fp >> 4) + filtered;
    }
    int16_t cal_base = (int16_t)(cal_baseline_fp >> 4);
    int16_t cal_dev = abs(filtered - cal_base);
    noise_floor_fp = noise_floor_fp - (noise_floor_fp >> NOISE_ALPHA_SHIFT)
                   + ((int32_t)cal_dev << (8 - NOISE_ALPHA_SHIFT));

    if (now - baseline_start >= BASELINE_TIME) {
      baseline_set = true;
      baseline_fp = (int32_t)(cal_baseline_fp >> 4) << 12;
      LED_BOTH_OFF();

      float base_mv = RAW_TO_FLOAT_MV(baseline_fp >> 12);
      float nf_mv = RAW_TO_FLOAT_MV(noise_floor_fp >> 8);

      Serial.println(F("========================================"));
      Serial.print(F("Baseline: "));
      Serial.print(base_mv, 1);
      Serial.println(F(" mV"));
      Serial.print(F("Noise floor: "));
      Serial.print(nf_mv, 1);
      Serial.println(F(" mV"));
      Serial.print(F("Resolution: "));
      Serial.print(RESOLUTION_UV);
      Serial.print(F("uV/LSB ("));
      Serial.print(OVERSAMPLE_BITS);
      Serial.println(F("-bit @ 1.1V)"));
      Serial.println(F("========================================"));
      Serial.println(F("Listening... A/V/D/C/X/O"));
      Serial.println(F("Format: elapsed,raw,mv,deviation"));
      Serial.println(F("----------------------------------------"));
    }
    return;
  }

  // ─── Commands + Stimulus ───
  check_serial_commands();
  execute_stimulus();

  // ─── Baseline + deviation (all raw) ───
  int16_t deviation = filtered - (int16_t)(baseline_fp >> 12);
  int16_t abs_dev = abs(deviation);
  int16_t base_raw = update_baseline(filtered, abs_dev);
  deviation = filtered - base_raw;
  abs_dev = abs(deviation);

  // ─── Statistics (raw) ───
  if (filtered < sig_min) sig_min = filtered;
  if (filtered > sig_max) sig_max = filtered;
  sig_sum += filtered;
  sig_count++;

  int16_t delta = filtered - prev_raw;

  if (delta > 0)       { trend_up++; trend_down = 0; }
  else if (delta < 0)  { trend_down++; trend_up = 0; }
  else                 { trend_up = 0; trend_down = 0; }

  // ─── Adaptive noise floor (raw) ───
  int16_t dyn_threshold;
  if (!in_event) {
    noise_floor_fp = noise_floor_fp - (noise_floor_fp >> NOISE_ALPHA_SHIFT)
                   + ((int32_t)abs_dev << (8 - NOISE_ALPHA_SHIFT));
  }
  int16_t nf_raw = (int16_t)(noise_floor_fp >> 8);
  dyn_threshold = constrain((int16_t)(nf_raw * NOISE_MULT),
                            MIN_THRESHOLD_RAW, MAX_THRESHOLD_RAW);

  // ─── Event detection (raw) ───
  if (!in_event && abs_dev > dyn_threshold) {
    in_event = true;
    event_start = now;
    event_count++;
    peak_val_raw = abs_dev;
    event_type = (abs(delta) > DELTA_THRESHOLD_RAW) ? 'A' : 'V';
    // SPIKE CLICK on Speaker L!
    click_sound(CLICK_FREQ_HZ, CLICK_DUR_MS);
  }

  if (in_event) {
    if (abs_dev > peak_val_raw) peak_val_raw = abs_dev;
    if (abs_dev < dyn_threshold / 2) {
      unsigned long dur = now - event_start;
      in_event = false;
      // End-of-event beep (lower, longer)
      click_sound(EVENT_BEEP_HZ, EVENT_BEEP_MS);
      // Convert peak to mV for display
      float peak_mv = RAW_TO_FLOAT_MV(peak_val_raw);
      char peak_str[10];
      dtostrf(peak_mv, 1, 1, peak_str);
      snprintf(tx_buf, sizeof(tx_buf),
        ">>> EVENT #%u | %c | Peak:%smV | Dur:%lums <<<",
        event_count, event_type, peak_str, dur);
      Serial.println(tx_buf);
    }
  }

  // ─── DRONE: deviation_raw → frequency ───
  // Map: deviation_raw through mV equivalent
  // drone_freq = 220 + deviation_mV * 13
  // = 220 + (deviation_raw * 1100 * 13) / 2^bits
  // = 220 + (deviation_raw * 14300) >> bits
  int16_t drone_freq = DRONE_BASE_HZ
    + (int16_t)(((int32_t)deviation * 14300L) >> OVERSAMPLE_BITS);
  set_drone_freq(drone_freq);

  // ─── FAN: activity EMA → PWM speed ───
  fan_activity_fp = fan_activity_fp
    - (fan_activity_fp >> FAN_ALPHA_SHIFT)
    + ((uint16_t)abs_dev << (8 - FAN_ALPHA_SHIFT));
  uint16_t activity_raw = fan_activity_fp >> 8;
  // Convert activity to mV-equivalent for fan scaling
  // fan_speed = activity_mV * 5 = (activity_raw * 5500) >> bits
  uint8_t fan_speed = (uint8_t)constrain(
    (int32_t)((uint32_t)activity_raw * 5500UL) >> OVERSAMPLE_BITS,
    0, 255);
  set_fan_speed(fan_speed);

  // ─── LEDs ───
  if (abs_dev > dyn_threshold) {
    if (deviation > 0) { LED_G_ON(); LED_R_OFF(); }
    else               { LED_G_OFF(); LED_R_ON(); }
  } else {
    // Breathing pulse: gentle blink proportional to activity
    uint16_t act_mv = (uint16_t)(((uint32_t)activity_raw * 1100UL) >> OVERSAMPLE_BITS);
    bool pulse = (act_mv > 2) && ((now >> 8) & 1);
    if (pulse) LED_G_ON(); else LED_G_OFF();
    LED_R_OFF();
  }

  // ─── CSV output — convert to mV with 0.1mV precision ───
  if (now - last_print >= PRINT_INTERVAL) {
    last_print = now;
    uint32_t elapsed_ms = now - start_time;
    uint16_t secs = elapsed_ms / 1000;
    uint8_t cents = (elapsed_ms % 1000) / 10;

    // Format: elapsed,raw,mv,deviation
    // mv and deviation now have 0.1mV resolution
    char mv_str[12], dev_str[12];
    dtostrf(RAW_TO_FLOAT_MV(filtered), 1, 1, mv_str);
    dtostrf(RAW_TO_FLOAT_MV(deviation), 1, 1, dev_str);

    int len = snprintf(tx_buf, sizeof(tx_buf),
      "%u.%02u,%u,%s,%s",
      secs, cents, raw, mv_str, dev_str);
    tx_buf[len++] = '\n';
    Serial.write((uint8_t*)tx_buf, len);
  }

  // ─── Periodic stats ───
  if (now - last_stats >= STATS_INTERVAL && sig_count > 0) {
    last_stats = now;
    float mean_mv = RAW_TO_FLOAT_MV(sig_sum / (int32_t)sig_count);
    float min_mv = RAW_TO_FLOAT_MV(sig_min);
    float max_mv = RAW_TO_FLOAT_MV(sig_max);
    float range_mv = max_mv - min_mv;
    float base_mv = RAW_TO_FLOAT_MV(base_raw);
    float nf_mv = RAW_TO_FLOAT_MV(nf_raw);
    float thr_mv = RAW_TO_FLOAT_MV(dyn_threshold);

    Serial.println(F("--- STATS ---"));
    Serial.print(F("  Mean:")); Serial.print(mean_mv, 1);
    Serial.print(F(" Rng:")); Serial.print(min_mv, 1);
    Serial.print('-'); Serial.print(max_mv, 1);
    Serial.print('('); Serial.print(range_mv, 1); Serial.print(')');
    Serial.print(F(" Base:")); Serial.print(base_mv, 1);
    Serial.print(F(" NF:")); Serial.print(nf_mv, 1);
    Serial.print(F(" Thr:")); Serial.print(thr_mv, 1);
    Serial.print(F(" Evt:")); Serial.print(event_count);
    Serial.print(F(" Fan:")); Serial.println(fan_speed);
    Serial.println(F("-------------"));

    sig_min = 32767; sig_max = 0;
    sig_sum = 0; sig_count = 0;
  }

  prev_raw = filtered;
}
