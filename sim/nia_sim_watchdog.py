# ---------------------------------------------------------------------------
# File        : nia_sim_watchdog.py
# Description : The wall clock guard around a simulation: it reports the state of the
#               boundary it was watching when a run stalls, and exits rather than hanging
#               a dispatch.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import sys
import traceback

try:
    import cocotb
    from cocotb.triggers import Timer, First
    from cocotb.utils import get_sim_time

    _HAVE_COCOTB = True
except Exception as _e:
    cocotb = None
    Timer = First = None
    get_sim_time = None
    _HAVE_COCOTB = False
    _COCOTB_ERR = _e

class NiaSimStall(AssertionError):
    pass

UNREADABLE = "<unreadable>"
ABSENT = "<absent>"

WALL_SECS_DEFAULT = 600.0

def wallclock_guard(name, snapshot=None, secs=None, env="NIA_WALL_SECS", rc=3):
    import threading
    if secs is None:
        try:
            secs = float(os.environ.get(env, WALL_SECS_DEFAULT))
        except BaseException:
            secs = WALL_SECS_DEFAULT
    if not secs or secs <= 0:
        return None

    def _fire():
        try:
            print("\nNIA_WALLCLOCK_STALL name=%s wall=%.0fs - the simulator stopped making "
                  "progress in REAL time. A simulated-time watchdog cannot see this, which is why "
                  "this guard exists. NO VPI is read here by design." % (name, secs), flush=True)
            if snapshot is not None:
                try:
                    for ln in (snapshot() or ["  <snapshot empty>"]):
                        print("NIA_WALLCLOCK_STALL %s" % (ln,), flush=True)
                except BaseException:
                    print("NIA_WALLCLOCK_STALL <snapshot raised - nothing recorded>", flush=True)
            print("NIA_WALLCLOCK_STALL end of report - exiting rc=%d" % rc, flush=True)
        except BaseException:
            pass
        finally:
            try:
                sys.stdout.flush()
                sys.stderr.flush()
            except BaseException:
                pass
            os._exit(rc)

    t = threading.Timer(secs, _fire)
    t.daemon = True
    t.start()
    return t

def safe_call(fn, default=UNREADABLE):

    try:
        return fn()
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        return "<ERR %s: %s>" % (type(exc).__name__, str(exc)[:120])

def resolve(root, path):

    node = root
    for part in str(path).split("."):
        if node is None:
            return None, ABSENT
        idx = None
        if part.endswith("]") and "[" in part:
            part, _, rest = part.partition("[")
            try:
                idx = int(rest[:-1])
            except Exception:
                return None, "<bad-index %r>" % rest
        try:
            node = getattr(node, part)
        except Exception:
            try:
                node = node[part]
            except Exception:
                return None, ABSENT
        if idx is not None:
            try:
                node = node[idx]
            except Exception:
                return None, ABSENT
    return node, None

def safe_read(root, path):

    handle, note = resolve(root, path)
    if note is not None:
        return "%s = %s" % (path, note)
    val = safe_call(lambda: handle.value)
    if isinstance(val, str) and val.startswith("<"):
        return "%s = %s" % (path, val)
    as_int = safe_call(lambda: int(val), default=None)
    as_str = safe_call(lambda: str(val))
    if isinstance(as_int, int):
        return "%s = 0x%x (%d)" % (path, as_int, as_int)
    return "%s = %s (not an integer: x/z or a composite)" % (path, as_str)

DEFAULT_PROBES = (
    "rst", "resetn", "aresetn", "s_axi_aresetn",
    "s_axis_tx_tvalid", "s_axis_tx_tready", "s_axis_tx_tlast",
    "m_axis_rx_tvalid", "m_axis_rx_tready", "m_axis_rx_tlast",
    "tx_axis_tvalid", "tx_axis_tready", "rx_axis_tvalid", "rx_axis_tready",
    "tx_serdes_valid", "rx_serdes_valid",
    "stat_tx_frame_count", "stat_rx_frame_count", "stat_rx_bad_frame_count",
    "seam_status", "mac_up", "tx_rdy", "rx_aligned", "rx_status",
    "ctl_seq_state", "ctl_seq_done", "ctl_seq_pc",
    "s_axi_awvalid", "s_axi_awready", "s_axi_wvalid", "s_axi_bvalid",
    "s_axi_arvalid", "s_axi_rvalid",
    "rq_tvalid", "rq_tready", "rc_tvalid", "cq_tvalid", "cc_tvalid",
    "msi_vector_valid", "irq", "irq_valid",
)

def dump_state(dut, probes=None, header="NIA_WATCHDOG DUMP", extra=None, max_probes=None):

    if max_probes is None:
        max_probes = int(os.environ.get("NIA_STALL_DUMP_MAX", "64") or 64)
    lines = [header]
    lines.append("  dut         = %s" % safe_call(lambda: dut._name if dut is not None else ABSENT))
    if _HAVE_COCOTB and get_sim_time is not None:
        lines.append("  sim time    = %s ns" % safe_call(lambda: get_sim_time("ns")))
    for key, val in (extra or {}).items():
        lines.append("  %-11s = %s" % (str(key)[:11], safe_call(lambda v=val: str(v))))
    plist = list(probes if probes is not None else DEFAULT_PROBES)
    shown = plist[:max_probes]
    lines.append("  --- %d probe(s)%s ---"
                 % (len(shown), "" if len(shown) == len(plist)
                    else " of %d (NIA_STALL_DUMP_MAX)" % len(plist)))
    for p in shown:
        lines.append("    " + safe_read(dut, p))
    lines.append("  --- watchdog stack (truncated) ---")
    stack = safe_call(lambda: "".join(traceback.format_stack(limit=6)))
    if isinstance(stack, str):
        for ln in stack.splitlines()[-8:]:
            lines.append("    " + ln.rstrip()[:160])
    lines.append("  THIS IS A STALL, NOT A SLOW RUN: simulated time advanced while the")
    lines.append("  progress token did not. The failure below is intentional (section A.2b).")
    return lines

class NiaWatchdog:

    def __init__(self, dut, progress=None, probes=None, stall_ns=None, check_ns=None, name=None):
        self.dut = dut
        self.probes = probes
        self.name = name or os.environ.get("NIA_JOB_NAME", "test")
        self.stall_ns = float(stall_ns if stall_ns is not None
                              else os.environ.get("NIA_STALL_NS", 20000) or 20000)
        if check_ns is not None:
            self.check_ns = float(check_ns)
        else:
            env = os.environ.get("NIA_STALL_CHECK_NS")
            self.check_ns = float(env) if env else max(1.0, self.stall_ns / 10.0)
        self._progress_fn = progress
        self._beats = 0
        self._last_note = "<none>"
        self._task = None
        self.fired = False

    def beat(self, note=None):

        self._beats += 1
        if note is not None:
            self._last_note = str(note)[:120]

    def token(self):

        if self._progress_fn is None:
            return ("beats", self._beats)
        return ("fn", safe_call(lambda: self._progress_fn()))

    async def _loop(self):
        if not _HAVE_COCOTB:
            raise RuntimeError("NiaWatchdog needs cocotb: %r" % (_COCOTB_ERR,))
        last = self.token()
        quiet_ns = 0.0
        while True:
            await Timer(self.check_ns, units="ns")
            now = self.token()
            if now != last:
                last = now
                quiet_ns = 0.0
                continue
            quiet_ns += self.check_ns
            if quiet_ns >= self.stall_ns:
                self.fired = True
                self._report(quiet_ns, now)
                raise NiaSimStall(
                    "NIA_WATCHDOG STALL job=%s: no progress for %g ns of simulated time "
                    "(limit NIA_STALL_NS=%g). Last token=%r last beat note=%r. "
                    "State dump is above." % (self.name, quiet_ns, self.stall_ns,
                                              now, self._last_note))

    def _report(self, quiet_ns, tok):
        lines = dump_state(
            self.dut, self.probes,
            header="NIA_WATCHDOG STALL job=%s quiet=%gns limit=%gns" % (self.name, quiet_ns, self.stall_ns),
            extra={"token": tok, "beats": self._beats, "lastbeat": self._last_note},
        )
        for ln in lines:
            emitted = safe_call(lambda l=ln: (self.dut._log.info(l) if self.dut is not None
                                              and hasattr(self.dut, "_log") else print(l)))
            if isinstance(emitted, str) and emitted.startswith("<ERR"):
                safe_call(lambda l=ln: print(l))

    def start(self):

        if not _HAVE_COCOTB:
            raise RuntimeError("NiaWatchdog needs cocotb: %r" % (_COCOTB_ERR,))
        starter = getattr(cocotb, "start_soon", None) or getattr(cocotb, "fork", None)
        self._task = starter(self._loop())
        return self._task

    def stop(self):
        if self._task is not None:
            safe_call(lambda: self._task.kill())
            self._task = None

    async def guard(self, coro):

        if not _HAVE_COCOTB:
            raise RuntimeError("NiaWatchdog needs cocotb: %r" % (_COCOTB_ERR,))
        starter = getattr(cocotb, "start_soon", None) or getattr(cocotb, "fork", None)
        body = starter(coro)
        wd = starter(self._loop())
        try:
            await First(body, wd)
        finally:
            safe_call(lambda: wd.kill())
        if self.fired:
            raise NiaSimStall(
                "NIA_WATCHDOG STALL job=%s: no progress for >= %g ns of simulated time "
                "(NIA_STALL_NS). See the dump above." % (self.name, self.stall_ns))
        exc = safe_call(lambda: body._outcome, default=None)
        safe_call(lambda: body.kill())
        return exc
