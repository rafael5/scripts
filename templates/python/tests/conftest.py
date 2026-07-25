import sys
from pathlib import Path

# Make src/ importable without requiring `pip install -e .`
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

# Shared pytest fixtures go here
