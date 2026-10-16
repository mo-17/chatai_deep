Flutter builds bundle the Matcha Chinese Baker acoustic model and Vocos vocoder.
The large binaries are ignored by Git. Before building a clean checkout, run:

```sh
python3 tool/prepare_bundled_tts.py
```

The script downloads official sherpa-onnx release assets, checks pinned SHA-256
digests, and installs the runtime files with this directory's manifest. Existing
assets are validated and left untouched; incomplete existing assets cause an error.
CI caches the prepared directory using the script and manifest as its cache key.

Upstream model and download instructions:
https://k2-fsa.github.io/sherpa/onnx/tts/all/Chinese/matcha-icefall-zh-baker.html
