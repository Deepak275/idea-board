"""Pytest bootstrap.

Ensures the backend package root (this directory) is importable regardless of
where pytest is invoked from, so ``import app`` resolves during tests.
"""

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
