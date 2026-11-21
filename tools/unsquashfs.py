import sys, os, pathlib
from PySquashfsImage import SquashFsImage

src, dst = sys.argv[1], pathlib.Path(sys.argv[2])
img = SquashFsImage.from_file(src)
files = links = nodes = 0
for f in img:
    p = dst / f.path.lstrip("/")
    p.parent.mkdir(parents=True, exist_ok=True)
    if f.is_file:
        p.write_bytes(f.read_bytes())
        files += 1
    elif f.is_dir:
        p.mkdir(parents=True, exist_ok=True)
    elif f.is_symlink:
        if not p.exists():
            os.symlink(f.inode._symlink.decode(), p)
        links += 1
    else:
        # devices, fifos, sockets: recorded as empty placeholders, not mknod'd
        p.touch()
        nodes += 1
    if not f.is_symlink:
        os.chmod(p, f.mode)
        os.utime(p, (f.time, f.time))
print(f"{src}: {files} files, {links} symlinks, {nodes} special -> {dst}")
