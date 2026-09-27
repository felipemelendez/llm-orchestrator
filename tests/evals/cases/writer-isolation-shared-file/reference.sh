#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
cat > registry.py <<'PY'
"""Value handlers.

Every handler is a one-argument function registered in HANDLERS below.
dispatch() is the only public entry point.
"""


def identity(value):
    return value


def stringify(value):
    return str(value)


def alpha(value):
    return value * 2


def beta(value):
    return value + 10


def gamma(value):
    return value ** 2


def delta(value):
    return -value


def epsilon(value):
    return value // 2


def zeta(value):
    return value * 100


HANDLERS = {
    "identity": identity,
    "stringify": stringify,
    "alpha": alpha,
    "beta": beta,
    "gamma": gamma,
    "delta": delta,
    "epsilon": epsilon,
    "zeta": zeta,
}


def dispatch(name, value):
    return HANDLERS[name](value)
PY
