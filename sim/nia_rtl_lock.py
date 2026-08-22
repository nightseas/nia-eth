#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : nia_rtl_lock.py
# Description : The lock a simulation set takes before it mutates a shared reference tree,
#               so two runs cannot mutate it at once.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import fcntl
import os
import pathlib
import sys
import time
from contextlib import contextmanager

LOCK_DIR = os.environ.get("NIA_LOCK_DIR", "/tmp")

def lock_path(protected_dir: str) -> pathlib.Path:

    key = str(protected_dir).strip("/").replace("/", "_").replace(".", "_")
    return pathlib.Path(LOCK_DIR) / f"nia_rtl_lock.{key}"

def nia_rtl_root(start: str = None) -> str:

    p = pathlib.Path(start or __file__).resolve()
    for anc in [p] + list(p.parents):
        cand = anc / "app" / "pcie_versal" / "rtl"
        if cand.is_dir():
            return str(cand)
    for anc in p.parents:
        if anc.name == "pcie_versal" and (anc / "rtl").is_dir():
            return str(anc / "rtl")
    for anc in p.parents:
        if (anc / "rtl").is_dir() and (anc / "sim").is_dir():
            return str(anc / "rtl")
    raise RuntimeError("nia_rtl_root: could not locate app/pcie_versal/rtl from " + str(p))

@contextmanager
def rtl_lock(protected_dir: str, who: str = "", timeout=None, quiet: bool = False):

    lp = lock_path(protected_dir)
    lp.parent.mkdir(parents=True, exist_ok=True)
    fh = open(lp, "a+")
    t0 = time.time()
    waited = False
    try:
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                waited = True
                if timeout is not None and (time.time() - t0) > timeout:
                    holder = ""
                    try:
                        fh.seek(0)
                        holder = fh.read().strip().splitlines()[-1:]
                    except Exception:
                        pass
                    raise TimeoutError(
                        f"NIA_RTL_LOCK timeout after {timeout}s on {lp} "
                        f"(held by: {holder}). Another mutator is running; "
                        f"in-place mutation cannot be parallelised - see this file's header."
                    )
                if not quiet and int(time.time() - t0) % 30 == 0:
                    print(f"NIA_RTL_LOCK waiting {int(time.time()-t0)}s for {lp} ({who})",
                          flush=True)
                time.sleep(1)
        if waited and not quiet:
            print(f"NIA_RTL_LOCK acquired after {time.time()-t0:.0f}s ({who})", flush=True)
        elif not quiet:
            print(f"NIA_RTL_LOCK acquired immediately ({who})", flush=True)
        fh.seek(0, os.SEEK_END)
        fh.write(f"{time.strftime('%F %T')} pid={os.getpid()} {who}\n")
        fh.flush()
        yield
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()
            if not quiet:
                print(f"NIA_RTL_LOCK released ({who})", flush=True)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        import subprocess
        import tempfile
        here = pathlib.Path(__file__).resolve().parent
        holder_src = (
            "import sys, time\n"
            f"sys.path.insert(0, {str(here)!r})\n"
            "from nia_rtl_lock import rtl_lock\n"
            "with rtl_lock('selftest', who='holder'):\n"
            "    time.sleep(3)\n"
        )
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as tf:
            tf.write(holder_src)
            holder_py = tf.name
        child = subprocess.Popen([sys.executable, holder_py])
        time.sleep(0.7)
        t0 = time.time()
        with rtl_lock("selftest", who="waiter"):
            waited = time.time() - t0
        child.wait()
        os.unlink(holder_py)
        ok = waited >= 2.0
        print(f"SELFTEST waited={waited:.1f}s (must be >= 2.0) -> {'PASS' if ok else 'FAIL'}")
        sys.exit(0 if ok else 1)
    print(__doc__)
