import sys
from pathlib import Path

import pytest

# WHY: cell_rules is not a test file, so pytest would not rewrite its asserts without this.
pytest.register_assert_rewrite("cell_rules")

REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
