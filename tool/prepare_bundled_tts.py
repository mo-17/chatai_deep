#!/usr/bin/env python3
"""Prepare the ignored, checksum-pinned speech assets needed by Flutter builds."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
NAME = "matcha-icefall-zh-baker"
DESTINATION = ROOT / "chatgpt_flutter/assets/sherpa_onnx" / NAME
RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
MANIFEST = ROOT / "tool/tts/manifest.json"
DOWNLOADS = (
    (f"{RELEASE}/tts-models/{NAME}.tar.bz2",
     "c3e1889c1b745180445daba6c1f51fb4aeceaff8500da425da6c5ff80e8620c5"),
    (f"{RELEASE}/vocoder-models/vocos-22khz-univ.onnx",
     "0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081"),
)


def validate(directory):
    manifest = json.loads(MANIFEST.read_text())
    if json.loads((directory / "manifest.json").read_text()) != manifest:
        raise ValueError("Existing TTS manifest differs; leaving assets untouched")
    for key in ("acousticModel", "vocoder", "tokens", "lexicon"):
        if not (directory / manifest[key]).is_file():
            raise ValueError(f"Missing TTS asset: {manifest[key]}")
    for name in manifest["ruleFsts"]:
        if not (directory / name).is_file():
            raise ValueError(f"Missing TTS rule: {name}")
    if not any((directory / manifest["dictDir"]).glob("*")):
        raise ValueError("Missing TTS dictionary")


def main():
    if DESTINATION.exists():
        validate(DESTINATION)
        print("Bundled TTS assets already prepared")
        return
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tts-", dir=DESTINATION.parent) as tmp:
        staging = Path(tmp)
        for url, expected in DOWNLOADS:
            output = staging / url.rsplit("/", 1)[-1]
            subprocess.run(["curl", "--fail", "--location", "--retry", "3",
                            "--output", str(output), url], check=True)
            with output.open("rb") as source:
                digest = hashlib.sha256()
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != expected:
                raise ValueError(f"Checksum mismatch: {output.name}")
        bundle = staging / "bundle"
        bundle.mkdir()
        with tarfile.open(staging / f"{NAME}.tar.bz2") as archive:
            for member in archive.getmembers():
                path = Path(member.name)
                if path.is_absolute() or ".." in path.parts or path.parts[0] != NAME:
                    raise ValueError("Unexpected archive path")
                if member.isdir():
                    continue
                if not member.isfile():
                    raise ValueError("Unexpected archive link or special file")
                # Package only the runtime resources declared by pubspec.yaml.
                if path.name not in {"model-steps-3.onnx", "tokens.txt", "lexicon.txt",
                                     "phone.fst", "date.fst", "number.fst"} and "dict" not in path.parts:
                    continue
                target = bundle / path
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
        shutil.copy2(staging / "vocos-22khz-univ.onnx", bundle)
        shutil.copy2(MANIFEST, bundle / "manifest.json")
        validate(bundle)
        bundle.rename(DESTINATION)
    print("Bundled TTS assets prepared and checksums verified")


if __name__ == "__main__":
    main()
