# ---------------------------------------------------------------------------
# File        : seg_bfm_multi.py
# Description : The multi client view over the segmented bus model, which presents one
#               client's signals out of a bus that carries several.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SUFFIX_FMT = "_c{}"

SEG_SIGNALS = (
    "rx_seg_valid", "rx_seg_dat", "rx_seg_ena", "rx_seg_sop", "rx_seg_eop",
    "rx_seg_err", "rx_seg_mty",
    "tx_seg_ready", "tx_seg_valid", "tx_seg_dat", "tx_seg_ena", "tx_seg_sop",
    "tx_seg_eop", "tx_seg_err", "tx_seg_mty",
)

class ClientView:
    def __init__(self, dut, client, extra=(), suffix_fmt=SUFFIX_FMT):
        self._dut = dut
        self._client = int(client)
        self._suffix = suffix_fmt.format(int(client))
        self._names = set(SEG_SIGNALS) | set(extra)

    @property
    def client(self):
        return self._client

    @property
    def suffix(self):
        return self._suffix

    def raw(self):
        return self._dut

    def name_of(self, base):
        return base + self._suffix if base in self._names else base

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        resolved = name + self._suffix if name in self._names else name
        try:
            return getattr(self._dut, resolved)
        except AttributeError as e:
            raise AttributeError(
                f"seg_bfm_multi: client {self._client} asked for `{name}`, resolved to "
                f"`{resolved}`, and the harness does not have it.  This is deliberately fatal: "
  f"silently falling back to `{name}` would let an / isolation test drive "
                f"the WRONG client and still report PASS. ({e})"
            ) from None

def client_view(dut, client, extra=(), suffix_fmt=SUFFIX_FMT):
    return ClientView(dut, client, extra=extra, suffix_fmt=suffix_fmt)

def axis_prefix(base, client, suffix_fmt=SUFFIX_FMT):
    return base + suffix_fmt.format(int(client))
