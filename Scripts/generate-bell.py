#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Generate the original, short system-alert-style bell; no sampled audio is used."""

import argparse
import io
import math
from pathlib import Path
import struct
import wave


DESTINATION = Path(__file__).resolve().parents[1] / "Frameworks/Resources/bell.wav"
SAMPLE_RATE = 48_000
DURATION = 0.22


def render() -> bytes:
    samples = []
    # A clear fundamental with quickly damped partials, rather than a melody.
    partials = ((1568.0, 1.0, 0.045), (3136.0, 0.18, 0.026), (4312.0, 0.07, 0.018))
    for index in range(round(SAMPLE_RATE * DURATION)):
        time = index / SAMPLE_RATE
        attack = math.sin(min(time / 0.002, 1.0) * math.pi / 2) ** 2
        release = math.sin(min((DURATION - time) / 0.025, 1.0) * math.pi / 2) ** 2
        tone = sum(
            amplitude * math.exp(-time / decay) * math.sin(math.tau * frequency * time)
            for frequency, amplitude, decay in partials
        )
        samples.append(tone * attack * release)
    samples[-1] = 0.0
    gain = 0.28 * 32767 / max(abs(sample) for sample in samples)
    pcm = b"".join(struct.pack("<h", round(sample * gain)) for sample in samples)
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setparams((1, 2, SAMPLE_RATE, len(samples), "NONE", "not compressed"))
        audio.writeframes(pcm)
    return output.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the checked-in WAV without changing it.")
    args = parser.parse_args()
    audio = render()
    if args.check:
        if not DESTINATION.exists() or DESTINATION.read_bytes() != audio:
            raise SystemExit("bell.wav differs from the generator; run Scripts/generate-bell.py.")
    else:
        DESTINATION.write_bytes(audio)


if __name__ == "__main__":
    main()
