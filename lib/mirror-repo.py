#!/usr/bin/env python3
"""Mirrors a pfSense CE pkg repository locally.

The signed repository metadata is copied verbatim, so pkg's signature
verification stays valid against the local mirror. Packages are verified
with pkg's own checksum format.

  mirror-repo.py <dir> <version...> [--full] [--jobs N] [--host URL]

Without --full only the dependency closure needed for installation is
fetched. Careful: pkg can pull in packages beyond the declared dependencies,
so use --full for media that must be complete.
"""
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pkgsum import verify

DEFAULT_HOST = "http://pkg01-atx.netgate.com"
TARGETS = [
    "pkg",
    "pfSense-base",
    "pfSense-kernel-pfSense",
    "pfSense-default-config",
    "pfSense-default-config-serial",
    "pfSense",
]
META = ["meta.conf", "meta", "packagesite.pkg", "data.pkg"]


def extract_packagesite(pkgfile, destdir):
    """packagesite.pkg is a zstd-compressed tar. Tries several ways per platform."""
    target = os.path.join(destdir, "packagesite.yaml")
    if os.path.exists(target) and os.path.getsize(target) > 0:
        return True

    # 1) tar with zstd support (GNU tar, recent libarchive)
    r = subprocess.run(["tar", "xf", pkgfile, "-C", destdir],
                       capture_output=True)
    if r.returncode == 0 and os.path.exists(target):
        return True

    # 2) zstd + tar pipeline
    for sevenz in ("zstd",):
        if shutil.which(sevenz):
            try:
                with open(os.path.join(destdir, "_ps.tar"), "wb") as out:
                    z = subprocess.run([sevenz, "-dc", pkgfile], stdout=out,
                                       stderr=subprocess.DEVNULL)
                if z.returncode == 0:
                    subprocess.run(["tar", "xf", os.path.join(destdir, "_ps.tar"),
                                    "-C", destdir], capture_output=True)
                    os.unlink(os.path.join(destdir, "_ps.tar"))
                    if os.path.exists(target):
                        return True
            except OSError:
                pass

    # 3) 7-Zip (two steps: .pkg -> .tar -> contents)
    for sevenz in ("7z", "7zz", "7za"):
        if shutil.which(sevenz):
            subprocess.run([sevenz, "x", "-y", f"-o{destdir}", pkgfile],
                           capture_output=True)
            tarname = os.path.join(destdir, "packagesite")
            for cand in (tarname, tarname + ".tar"):
                if os.path.exists(cand):
                    subprocess.run([sevenz, "x", "-y", f"-o{destdir}", cand],
                                   capture_output=True)
                    os.unlink(cand)
            if os.path.exists(target):
                return True

    # 4) python zstandard module
    try:
        import tarfile
        import zstandard
        with open(pkgfile, "rb") as fh:
            dctx = zstandard.ZstdDecompressor()
            with dctx.stream_reader(fh) as reader:
                with tarfile.open(fileobj=reader, mode="r|") as tf:
                    tf.extractall(destdir)
        return os.path.exists(target)
    except Exception:
        return False


def log(*a):
    print(*a, flush=True)


def fetch(url, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return "cached"
    r = subprocess.run(
        ["curl", "-sfL", "--retry", "5", "--retry-delay", "3",
         "--max-time", "900", "-o", dest + ".part", url]
    )
    if r.returncode != 0:
        if os.path.exists(dest + ".part"):
            os.unlink(dest + ".part")
        return "FAIL"
    os.replace(dest + ".part", dest)
    return "ok"


def repo_names(version):
    vtag = version.replace(".", "_")
    return [f"pfSense_v{vtag}_amd64-core",
            f"pfSense_v{vtag}_amd64-pfSense_v{vtag}"]


def mirror(version, outroot, host, full, workers):
    db = {}
    for r in repo_names(version):
        for m in META:
            st = fetch(f"{host}/{r}/{m}", f"{outroot}/{r}/{m}")
            if st == "FAIL" and m in ("meta.conf", "packagesite.pkg"):
                log(f"  !! could not fetch {r}/{m}")
                return False
        d = f"{outroot}/{r}"
        if not extract_packagesite(f"{d}/packagesite.pkg", d):
            log("  !! could not unpack packagesite.pkg - needs tar with zstd "
                "support, 7z or the python zstandard module")
            return False
        for line in open(f"{d}/packagesite.yaml"):
            e = json.loads(line)
            e["_repo"] = r
            db.setdefault(e["name"], e)

    if full:
        need = set(db)
    else:
        need, stack = set(), list(TARGETS)
        while stack:
            n = stack.pop()
            if n in need:
                continue
            if n not in db:
                log(f"  !! dependency missing from the repository: {n}")
                return False
            need.add(n)
            stack.extend((db[n].get("deps") or {}).keys())

    total = sum(db[n]["pkgsize"] for n in need)
    have = sum(1 for n in need
               if os.path.exists(f"{outroot}/{db[n]['_repo']}/{db[n]['path']}"))
    log(f"  {len(need)} packages / {total / 1048576:.1f} MB "
        f"({have} already present)")
    done = [0]
    bad = []

    def grab(n):
        e = db[n]
        dest = f"{outroot}/{e['_repo']}/{e['path']}"
        if fetch(f"{host}/{e['_repo']}/{e['path']}", dest) == "FAIL":
            bad.append((n, "download"))
            return
        if not verify(dest, e.get("sum")):
            bad.append((n, "checksum"))
            os.unlink(dest)
            return
        done[0] += 1
        if done[0] % 50 == 0 or done[0] == len(need):
            log(f"  [{done[0]}/{len(need)}]")

    with ThreadPoolExecutor(max_workers=workers) as ex:
        list(ex.map(grab, sorted(need)))

    if bad:
        log(f"  !! failed ({len(bad)}): {bad[:10]}")
        return False
    log(f"  {version} mirror complete")
    return True


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    full = "--full" in args
    host = DEFAULT_HOST
    workers = 4
    if "--host" in args:
        host = args[args.index("--host") + 1]
    if "--jobs" in args:
        workers = int(args[args.index("--jobs") + 1])
    skip = set()
    for flag, has_val in (("--full", False), ("--host", True), ("--jobs", True)):
        if flag in args:
            i = args.index(flag)
            skip.add(i)
            if has_val:
                skip.add(i + 1)
    pos = [a for i, a in enumerate(args) if i not in skip]
    out, versions = pos[0], pos[1:]
    if not versions:
        print("no version given", file=sys.stderr)
        return 2
    ok = True
    for v in versions:
        ok &= mirror(v, f"{out}/{v}", host, full, workers)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
