import sys, os, glob
sys.path[:0]=['/home/claude/src/shim','/home/claude/src/UnityPy','/home/claude/src/texture2ddecoder','/home/claude/src/filesystem_spec']
import UnityPy
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for f in sorted(glob.glob(os.path.join(src, '*.bundle'))):
    env = UnityPy.load(f)
    for o in env.objects:
        if o.type.name in ('Texture2D','Sprite'):
            try:
                d = o.read()
                name = d.m_Name
                if 'icon' in name.lower() or 'tex' in name.lower():
                    p = os.path.join(out, f"{o.type.name}_{name}.png")
                    if not os.path.exists(p):
                        d.image.save(p); print(os.path.basename(f)[:30], o.type.name, name, d.image.size)
            except Exception as e:
                print('ERR', name if 'name' in dir() else '?', e)
