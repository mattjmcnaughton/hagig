"""Synthesize nonpersonal 16 kHz mono PCM16 fixtures from corpus.tsv.

macOS uses the built-in `say` and `afconvert`; elsewhere `espeak-ng` and `ffmpeg`.
No microphone, remote TTS, or personal recordings.
"""

import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile
import wave

source = pathlib.Path(__file__).parent / "corpus.tsv"
dest = pathlib.Path(sys.argv[1])
dest.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, dest / "corpus.tsv")
mac = platform.system() == "Darwin"
synth = "say/afconvert" if mac else "espeak-ng/ffmpeg"

for line in source.read_text().splitlines():
    name, _, _, spoken = line.split("\t")
    target = dest / f"{name}.wav"
    if not spoken:
        with wave.open(str(target), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            out.writeframes(b"\0\0" * 16000 * 3)
        continue
    with tempfile.TemporaryDirectory() as tmp:
        if mac:
            raw = str(pathlib.Path(tmp) / "speech.aiff")
            subprocess.run(["say", "-r", "175", "-o", raw, spoken], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", raw, str(target)], check=True)
        else:
            raw = str(pathlib.Path(tmp) / "speech.wav")
            subprocess.run(["espeak-ng", "-v", "en-us", "-s", "155", "-w", raw, spoken], check=True)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(target)], check=True)

(dest / "synthesizer.txt").write_text(f"{synth} on {platform.platform()}\n")
