"""
Minimal config loader, mirroring the `cfg_reader.primary.load(path)` pattern
used by llm-for-iac. Keeps all tunables (timeout, output dirs, sample file
location) in one YAML file instead of scattered across scripts.
"""

from pathlib import Path

import yaml

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[2] / "conf" / "config.yaml"


def load(path: str | Path = DEFAULT_CONFIG_PATH) -> dict:
    """Load the YAML config file into a plain dict."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"config file not found: {path}")

    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    return cfg
