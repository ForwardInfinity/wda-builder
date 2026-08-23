#!/usr/bin/env python3
"""Add only the iOS 26 WDA continued-processing declarations to Runner Info."""

from __future__ import annotations

import argparse
import plistlib
from pathlib import Path

FINAL_BUNDLE_ID = "com.ios-use.wda.00008101-00064d1a3a68001e"
PERMITTED = f"{FINAL_BUNDLE_ID}.wda-recovery.*"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runner_app", type=Path)
    args = parser.parse_args()
    info = args.runner_app / "Info.plist"
    with info.open("rb") as stream:
        value = plistlib.load(stream)
    value["BGTaskSchedulerPermittedIdentifiers"] = [PERMITTED]
    modes = list(value.get("UIBackgroundModes", []))
    if "processing" not in modes:
        modes.append("processing")
    value["UIBackgroundModes"] = modes
    with info.open("wb") as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_BINARY, sort_keys=True)
    with info.open("rb") as stream:
        checked = plistlib.load(stream)
    assert checked["BGTaskSchedulerPermittedIdentifiers"] == [PERMITTED]
    assert "processing" in checked["UIBackgroundModes"]
    print(f"JARVIS_WDA_RUNNER_INFO_PATCHED permitted={PERMITTED}")


if __name__ == "__main__":
    main()
