#!/usr/bin/env bash
# Retired. The per-tool-call evidence ledger is gone: it watched every command,
# guessed whether it might write, and hashed the whole repository to find out.
# Completion is now checked once, at Stop, by orch-verify-gate.sh reading the
# transcript the harness already writes.
#
# This stub stays only so a session that loaded the old hooks.json does not
# report a missing command. It is unregistered in hooks.json and can be removed.
exit 0
