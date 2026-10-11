"""mktools.py DIR EXCLUDED... : fill DIR with a symbolic link for every executable of the usual directories (/usr/local/sbin, /usr/local/bin,
/usr/sbin, /usr/bin, /sbin, /bin; the first one wins) except the names EXCLUDED: the tool set of a machine without those packages."""
import os
import sys

dest, excluded = sys.argv[1], set(sys.argv[2:])
os.makedirs(dest, exist_ok=True)
n = 0
for d in ("/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"):
    try:
        names = os.listdir(d)
    except OSError:
        continue
    for name in names:
        p = os.path.join(d, name)
        link = os.path.join(dest, name)
        if name in excluded or os.path.lexists(link) or not os.path.isfile(p) or not os.access(p, os.X_OK):
            continue
        os.symlink(os.path.realpath(p), link)
        n += 1
print(n)
