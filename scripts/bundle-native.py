#!/usr/bin/env python3
"""Copy only linked native libraries, rewrite install names, sign inside-out."""
import pathlib,subprocess,sys,shutil
app=pathlib.Path(sys.argv[1]).resolve(); prefix=pathlib.Path('.build/native').resolve()
frameworks=app/'Contents/Frameworks'
if frameworks.exists():shutil.rmtree(frameworks)
frameworks.mkdir()
executable=app/'Contents/MacOS/OpenStill'
queue=[executable];seen=set()
while queue:
 binary=queue.pop(0)
 if binary in seen:continue
 seen.add(binary)
 dependencies=subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]
 for row in dependencies:
  reference=row.strip().split(' (')[0]
  if reference.startswith(('/System/','/usr/lib/')):continue
  # Frameworks (Sparkle) are copied and signed by build-app.sh.
  if binary==executable and reference.startswith('@rpath/') and '.framework/' in reference:continue
  name=pathlib.Path(reference).name
  source=(prefix/'lib'/name) if reference.startswith('@rpath/') else pathlib.Path(reference)
  if binary!=executable and name==binary.name:continue
  if not source.exists() or not source.resolve().is_relative_to(prefix):
   raise SystemExit(f'Unbundled non-system dependency: {reference}')
  target=frameworks/name
  if not target.exists():shutil.copyfile(source,target)
  # Fail rather than distribute a dependency requiring a newer OS than the app.
  load=subprocess.check_output(['otool','-l',str(target)],text=True)
  for line in load.splitlines():
   if line.strip().startswith(('minos ','version ')):
    parts=line.split()
    if len(parts)>1 and parts[0]=='minos' and float('.'.join(parts[1].split('.')[:2]))>13.0:
     raise SystemExit(f'{name} requires macOS {parts[1]}')
  new=('@executable_path/../Frameworks/' if binary==executable else '@loader_path/')+name
  subprocess.run(['install_name_tool','-change',reference,new,str(binary)],check=True)
  queue.append(target)
 if binary!=executable:
  subprocess.run(['install_name_tool','-id','@rpath/'+binary.name,str(binary)],check=True)
for library in sorted(seen-{executable}):subprocess.run(['codesign','--force','--sign','-',str(library)],check=True)
