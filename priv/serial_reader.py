#!/usr/bin/env python3
"""Serial reader for Erlang port — handles DTR properly for CH340/Arduino."""
import sys
import serial
import time

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <device> <baud>", file=sys.stderr)
        sys.exit(1)

    device = sys.argv[1]
    baud = int(sys.argv[2])

    try:
        ser = serial.Serial(device, baud, timeout=10)
        ser.dtr = False  # prevent Arduino reset
        time.sleep(0.5)
        ser.reset_input_buffer()  # flush bootloader garbage

        while True:
            line = ser.readline()
            if not line:
                continue
            # Decode safely, skip non-ASCII garbage
            try:
                text = line.decode('ascii').strip()
                if text and all(32 <= ord(c) <= 126 for c in text):
                    sys.stdout.write(text + '\n')
                    sys.stdout.flush()
            except (UnicodeDecodeError, ValueError):
                continue

    except serial.SerialException as e:
        print(f"Serial error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        pass
    finally:
        if 'ser' in dir() and ser.is_open:
            ser.close()

if __name__ == '__main__':
    main()
