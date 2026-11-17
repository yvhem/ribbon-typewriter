"""Synthesize Ribbon's original typewriter sounds using the Python standard library."""
from array import array
from math import exp, pi, sin
from pathlib import Path
from random import Random
from sys import byteorder
import wave

RATE = 44100
destination = Path(__file__).resolve().parents[1] / "Sources/Ribbon/Resources/Audio/original"

# Each collision sets a few metal resonances ringing over a short noise transient.
def impact(samples, random, when, gain, frequencies, decay, grit):
    start = round(when * RATE)
    colored_noise = 0.0
    pitch = random.uniform(0.93, 1.07)
    for index in range(start, min(start + round(decay * 9 * RATE), len(samples))):
        t = (index - start) / RATE
        noise = random.uniform(-1, 1)
        colored_noise = 0.56 * colored_noise + 0.44 * noise
        metal = sum(
            amplitude * sin(2 * pi * frequency * pitch * t) * exp(-t / (decay / (1 + band * 0.6)))
            for band, (frequency, amplitude) in enumerate(frequencies)
        )
        transient = (noise - 0.62 * colored_noise) * exp(-t / (decay * 0.28))
        onset = min(1.0, t * 8500)
        samples[index] += gain * onset * (metal + grit * transient)


def synthesize(kind, number):
    random = Random(f"Ribbon typewriter {kind}:{number}")
    duration = 0.30 if kind == "returnKey" else 0.15
    samples = [0.0] * round(duration * RATE)
    keytop = ((590, .18), (2590, .12), (4200, .07))
    platen = ((205, .23), (860, .12), (1770, .11), (3370, .08))
    bracket = ((325, .30), (1030, .17), (2930, .095))
    if kind == "key":
        impact(samples, random, 0, .48, keytop, .006, .49)
        impact(samples, random, random.uniform(.004, .010), .88, platen, .013, .50)
        impact(samples, random, random.uniform(.048, .073), .29, keytop, .007, .57)
    elif kind == "space":
        impact(samples, random, 0, .86, ((155, .42), (510, .18), (1360, .11)), .014, .38)
        impact(samples, random, .063, .27, bracket, .009, .55)
    elif kind == "backspace":
        impact(samples, random, 0, .73, bracket, .010, .55)
        impact(samples, random, .022, .32, keytop, .006, .52)
        impact(samples, random, .060, .25, bracket, .007, .44)
    else:
        impact(samples, random, 0, .62, bracket, .013, .64)
        for tooth in range(9):
            when = .019 + .009 * tooth + .00065 * tooth * tooth + random.uniform(-.002, .002)
            impact(samples, random, when, random.uniform(.23, .43), keytop, .005, .72)
        impact(samples, random, .151, .88, ((137, .39), (460, .21), (1930, .13)), .018, .60)

    samples = array("h", (round(max(-1, min(1, x)) * 32000) for x in samples))
    if byteorder != "little":
        samples.byteswap()
    with wave.open(str(destination / f"{kind}-{number}.wav"), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(samples.tobytes())


if __name__ == "__main__":
    destination.mkdir(parents=True, exist_ok=True)
    for kind, count in (("key", 8), ("space", 3), ("backspace", 3), ("returnKey", 3)):
        for variation in range(1, count + 1):
            synthesize(kind, variation)
