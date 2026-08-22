# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The make front end. Every target is a call into bin/nia-eth, so the flow
#               lives in one script and this file holds no logic of its own.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

TOOL := bin/nia-eth

.PHONY: help deps check sim elab image list targets hwtest clean

help:
	@$(TOOL) help

deps:
	@$(TOOL) deps

check:
	@$(TOOL) check

sim:
	@$(TOOL) sim

elab:
	@$(TOOL) elab

image:
	@$(TOOL) image

list:
	@$(TOOL) list

targets:
	@$(TOOL) targets

hwtest:
	@$(TOOL) hwtest $(ARGS)

clean:
	@$(TOOL) clean
