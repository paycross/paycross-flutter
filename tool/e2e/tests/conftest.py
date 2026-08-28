"""Puts the repo root on sys.path so `tool.e2e.*` resolves under pytest.

pytest inserts the *test* directory into sys.path, not the rootdir, while the
CLI imports the runner as `tool.e2e.runner`. Without this the two disagree and
every test file fails at import.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
