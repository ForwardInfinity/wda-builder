#!/usr/bin/env python3
"""Inject the phase-1 Jarvis reverse heartbeat into Appium WebDriverAgent."""

from __future__ import annotations

import argparse
from pathlib import Path

SOURCE_MARKER = "// Jarvis reverse-agent phase 1."
START_MARKER = "[[JVReverseAgent sharedAgent] start];"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("wda_root", type=Path)
    parser.add_argument(
        "--snippet",
        type=Path,
        default=Path(__file__).with_name("FBJarvisReverseAgent.inc.m"),
    )
    args = parser.parse_args()

    test_file = args.wda_root / "WebDriverAgentRunner" / "UITestingUITests.m"
    text = test_file.read_text(encoding="utf-8")
    snippet = args.snippet.read_text(encoding="utf-8").strip()
    if SOURCE_MARKER not in snippet:
        raise RuntimeError("reverse-agent snippet marker missing")
    if SOURCE_MARKER in text or START_MARKER in text:
        raise RuntimeError("WDA source already contains Jarvis reverse-agent patch")

    interface = "@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>"
    fallback = "@interface UITestingUITests : XCTestCase <FBWebServerDelegate>"
    anchor = interface if interface in text else fallback
    if anchor not in text:
        raise RuntimeError("UITestingUITests interface anchor not found")
    text = text.replace(anchor, f"{snippet}\n\n{anchor}", 1)

    serving = "  [webServer startServing];"
    if text.count(serving) != 1:
        raise RuntimeError("expected exactly one FBWebServer startServing call")
    text = text.replace(serving, f"  {START_MARKER}\n{serving}", 1)

    # Preserve the iOS 26.6 deadlock fix used by the already-proven WDA build.
    text = text.replace(
        "#import <WebDriverAgentLib/FBFailureProofTestCase.h>",
        "// Jarvis iOS 26 patch: no FBFailureProofTestCase import",
    )
    text = text.replace(interface, fallback)

    test_file.write_text(text, encoding="utf-8")
    result = test_file.read_text(encoding="utf-8")
    for marker in (SOURCE_MARKER, START_MARKER, fallback):
        if marker not in result:
            raise RuntimeError(f"post-patch marker missing: {marker}")
    print(f"JARVIS_WDA_REVERSE_AGENT_PATCHED file={test_file}")


if __name__ == "__main__":
    main()
