from pathlib import Path
import hashlib,json,shutil,sys
root=Path(__file__).resolve().parent.parent
src=root/'build/web'; dest=root/'launcher-web/web'
if not (src/'main.dart.js').is_file():sys.exit('Build web first: flutter build web --dart-define-from-file=config/supabase.json')
if dest.exists():sys.exit('Stop the launcher and move the old launcher-web/web directory aside before preparing a new build.')
shutil.copytree(src,dest)
files={p.relative_to(dest).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in dest.rglob('*') if p.is_file()}
(root/'launcher-web/web-files.json').write_text(json.dumps(files,indent=2),encoding='utf-8')
print('Prepared static web files. Run: python launcher-web/launcher.py')
