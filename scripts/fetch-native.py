#!/usr/bin/env python3
"""Fetch only manifest-pinned upstream archives; verify before unpacking."""
import hashlib, json, pathlib, tarfile, urllib.request
root = pathlib.Path(__file__).resolve().parents[1]
archives = root/'Resources/Licenses/NativeSources'
sources = root/'.build/native-sources'
archives.mkdir(parents=True,exist_ok=True); sources.mkdir(parents=True,exist_ok=True)
for spec in json.loads((root/'Resources/Licenses/native-dependencies.json').read_text()):
    name = spec['name']; url = spec['url']
    suffix = '.tar.xz' if url.endswith('.xz') else ('.tar.bz2' if url.endswith('.bz2') else '.tar.gz')
    archive = archives/(name+'-'+spec['version']+suffix)
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != spec['sha256']:
        temporary = archive.with_suffix('.download')
        with urllib.request.urlopen(url,timeout=120) as response, temporary.open('wb') as output:
            while True:
                chunk = response.read(1024*1024)
                if not chunk: break
                output.write(chunk)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != spec['sha256']:
            temporary.unlink(); raise RuntimeError('Checksum mismatch: '+name)
        temporary.replace(archive)
    destination = sources/name
    if not destination.exists():
        destination.mkdir()
        with tarfile.open(archive) as bundle:
            # Upstream archives have one top-level directory. Reject traversal/links
            # before extraction, and strip that known root into a stable build path.
            for member in bundle.getmembers():
                parts = pathlib.PurePosixPath(member.name).parts[1:]
                if not parts: continue
                if '..' in parts or member.issym() or member.islnk(): continue
                target = destination.joinpath(*parts)
                if member.isdir(): target.mkdir(parents=True,exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True,exist_ok=True)
                    with bundle.extractfile(member) as stream: target.write_bytes(stream.read())
                    target.chmod(member.mode & 0o777)
    print(name+' '+spec['version']+' verified',flush=True)
