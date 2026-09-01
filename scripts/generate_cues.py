#!/usr/bin/env python3
"""Write the two feedback cue files Murmure ships in its bundle.

    ./scripts/generate_cues.py            # rewrites Murmure/Sounds/*.wav

The sounds are synthesised rather than picked from /System/Library/Sounds, and the reason is
partly semantic and mostly measured.

SEMANTICS.  Every sound macOS ships is already spoken for. Basso is the failure chime; Sosumi,
Funk, Submarine, Hero and the rest are the alert sounds the user picks from in System Settings, so
whichever one is chosen here is, on some Mac, the sound of something going wrong. Pop and Tink are
UI ticks. None of them is a RISING interval, which is the one shape that is read everywhere --
Siri, Superwhisper, a huddle joining -- as "a window has opened, speak". So the start cue is a
rising perfect fifth (660 -> 990 Hz) and the insertion cue is a single note that does not rise,
because it closes something rather than opening it.

LENGTH, WHICH IS THE MEASURED PART.  The start cue plays through the speakers at the instant the
microphone starts capturing, so it can land in the WAV. SpeechGate scores a recording in 100 ms
frames and needs THREE voiced ones -- 0.3 s -- before the recording is transcribed at all. A cue
long enough to fill three frames would therefore make a dictation in which Louis said nothing look
like speech, hand it to Whisper, and get a fabricated sentence pasted -- the exact failure
SpeechGate exists to prevent.

An earlier 180 ms draft did exactly that: mixed into 3 s of Louis's own room tone it scored 3
voiced frames -- SPEECH -- at every alignment from 50 ms onward, down to 12 dB below its own peak.
At 90 ms it cannot. Swept over every 1 ms alignment inside a frame, and at gains from -20 dB to
+6 dB, the start cue never occupies more than 2 voiced frames and the insertion cue never more
than 2. That is a property of its LENGTH, so it holds at any playback volume, on speakers or in
headphones, whatever the acoustic coupling turns out to be. Keep the cue under 100 ms.

LEVEL.  Peak -13 dBFS (0.22), the middle of what Apple ships (Glass 0.198, Submarine 0.230,
Bottle 0.235, Tink 0.365, Hero 0.534), so Louis's existing volume setting is already calibrated
for it. The insertion cue is 7 dB below that: it confirms an outcome he can already see, where the
start cue opens a window for speech.
"""

import math
import pathlib
import struct
import wave

SAMPLE_RATE = 48_000


def render(partials, total_seconds):
    """Sum sine partials, each with a raised-cosine attack and an exponential decay.

    partials: (frequency_hz, start_s, duration_s, amplitude, attack_s, decay_s)
    """
    samples = [0.0] * int(total_seconds * SAMPLE_RATE)
    for frequency, start, duration, amplitude, attack, decay in partials:
        offset = int(start * SAMPLE_RATE)
        for i in range(int(duration * SAMPLE_RATE)):
            t = i / SAMPLE_RATE
            envelope = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / attack))
            envelope *= math.exp(-t / decay)
            if offset + i < len(samples):
                samples[offset + i] += (
                    amplitude * envelope * math.sin(2 * math.pi * frequency * t)
                )
    return samples


def write(path, samples, peak):
    gain = peak / max(abs(v) for v in samples)
    with wave.open(str(path), "w") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(
            b"".join(
                struct.pack("<h", int(max(-1.0, min(1.0, v * gain)) * 32767))
                for v in samples
            )
        )
    print(f"{path.name}: {len(samples) / SAMPLE_RATE * 1000:.0f} ms, peak {peak:.3f}")


# 660 -> 990 Hz, a fifth up, each note with a quiet octave above it for body. 90 ms total.
START = render(
    [
        (660, 0.000, 0.045, 1.00, 0.003, 0.016),
        (1320, 0.000, 0.030, 0.20, 0.003, 0.010),
        (990, 0.042, 0.048, 0.95, 0.003, 0.016),
        (1980, 0.042, 0.030, 0.18, 0.003, 0.010),
    ],
    0.090,
)

# One note, no interval: nothing here should read as "opening". 40 ms.
INSERTED = render(
    [
        (1320, 0.0, 0.038, 1.00, 0.003, 0.012),
        (2640, 0.0, 0.026, 0.16, 0.003, 0.008),
    ],
    0.040,
)

if __name__ == "__main__":
    sounds = pathlib.Path(__file__).resolve().parent.parent / "Murmure" / "Sounds"
    sounds.mkdir(parents=True, exist_ok=True)
    write(sounds / "cue-recording-started.wav", START, 0.22)
    write(sounds / "cue-text-inserted.wav", INSERTED, 0.10)
