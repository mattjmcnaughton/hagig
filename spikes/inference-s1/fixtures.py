"""Generate explicitly nonpersonal fixtures; no microphone or remote TTS."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import wave

source = pathlib.Path(__file__).parent / "corpus.tsv"
dest = pathlib.Path(sys.argv[1])
dest.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, dest / "corpus.tsv")
for line in source.read_text().splitlines():
    name, _, _, spoken = line.split("\t")
    target = dest / f"{name}.wav"
    if not spoken:
        with wave.open(str(target), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            out.writeframes(b"\0\0" * 16000 * 3)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            raw = str(pathlib.Path(tmp) / "speech.wav")
            subprocess.run(["espeak-ng", "-v", "en-us", "-s", "155", "-w", raw, spoken], check=True)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(target)], check=True)
