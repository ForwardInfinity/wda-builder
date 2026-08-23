#!/usr/bin/env python3
"""Apply iOS 26 WDA base-class fix and bounded host-continuation status."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wda_root", type=Path)
    args = parser.parse_args()

    test_file = args.wda_root / "WebDriverAgentRunner" / "UITestingUITests.m"
    text = test_file.read_text(encoding="utf-8")
    interface = "@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>"
    fallback = "@interface UITestingUITests : XCTestCase <FBWebServerDelegate>"
    if text.count(interface) != 1:
        raise RuntimeError("UITestingUITests interface anchor missing")
    text = text.replace(
        "#import <WebDriverAgentLib/FBFailureProofTestCase.h>",
        "// Jarvis iOS 26 patch: no FBFailureProofTestCase import",
        1,
    ).replace(interface, fallback, 1)
    test_file.write_text(text, encoding="utf-8")

    status_file = args.wda_root / "WebDriverAgentLib" / "Commands" / "FBSessionCommands.m"
    status_text = status_file.read_text(encoding="utf-8")
    status_anchor = '''  if (nil != version) {
    [buildInfo setObject:version forKey:@"version"];
  }
'''
    status_patch = status_anchor + '''  NSUserDefaults *jarvisDefaults = NSUserDefaults.standardUserDefaults;
  [buildInfo setObject:@{
    @"hook" : @([jarvisDefaults boolForKey:@"jarvis.wda.continued.hook"]),
    @"appState" : @([jarvisDefaults integerForKey:@"jarvis.wda.continued.appState"]),
    @"submitState" : @([jarvisDefaults integerForKey:@"jarvis.wda.continued.submitState"]),
    @"attempts" : @([jarvisDefaults integerForKey:@"jarvis.wda.continued.attempts"]),
    @"registered" : @([jarvisDefaults boolForKey:@"jarvis.wda.continued.registered"]),
    @"submitted" : @([jarvisDefaults boolForKey:@"jarvis.wda.continued.submitted"]),
    @"error" : @([jarvisDefaults integerForKey:@"jarvis.wda.continued.error"]),
    @"active" : @([jarvisDefaults boolForKey:@"jarvis.wda.continued.active"]),
  } forKey:@"jarvisContinued"];
'''
    if status_text.count(status_anchor) != 1 or "jarvisContinued" in status_text:
        raise RuntimeError("WDA status anchor missing or already patched")
    status_file.write_text(status_text.replace(status_anchor, status_patch, 1), encoding="utf-8")
    print(f"JARVIS_WDA_HOST_STATUS_PATCHED test={test_file} status={status_file}")


if __name__ == "__main__":
    main()
