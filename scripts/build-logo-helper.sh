#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
python3 - <<'PY'
import json,hashlib,urllib.request,tarfile
from pathlib import Path
manifest=json.loads(Path('Resources/Licenses/LogoAI/manifest.json').read_text())['runtime']
archive=Path('.build/llama-'+manifest['revision']+'.tar.gz')
if not archive.exists():urllib.request.urlretrieve(manifest['source'],archive)
if hashlib.sha256(archive.read_bytes()).hexdigest()!=manifest['sha256']:raise SystemExit('llama.cpp source checksum mismatch')
root=Path('.build/llama-source')
if not root.exists():
 root.mkdir()
 with tarfile.open(archive) as tf:
  for member in tf.getmembers():
   parts=Path(member.name).parts
   if len(parts)<2 or member.issym() or member.islnk():continue
   member.name=str(Path(*parts[1:]));tf.extract(member,root,filter='data')
PY
METAL=OFF
if [ "$(uname -m)" = arm64 ]; then METAL=ON; fi
cmake -S .build/llama-source -B .build/llama-native -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL="$METAL" -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_SUBPROCESS=OFF
cmake --build .build/llama-native --target llama-completion --parallel 4
