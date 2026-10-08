"""Verify Flutter registers the Rust backend only for Linux."""
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
for platform, plugins in manifest["plugins"].items():
    names = {plugin["name"] for plugin in plugins}
    assert "rhttp" not in names, f"Upstream rhttp still registered for {platform}"
    registered = "native_dio_adapter_desktop" in names
    assert registered == (platform == "linux"), f"Wrong native backend registration for {platform}"
print("Native Rust plugin is registered only for Linux.")
