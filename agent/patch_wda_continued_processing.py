#!/usr/bin/env python3
"""Keep loopback WDA alive with an official iOS 26 continued-processing task."""

from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "// Jarvis WDA continued-processing v1."
CALL = "  JVStartWDAContinuedProcessing();"

SNIPPET = r'''
// Jarvis WDA continued-processing v1.
static BGContinuedProcessingTask *JVWDAContinuedTask;
static dispatch_source_t JVWDAProgressTimer;
static id JVWDAForegroundObserver;
static BOOL JVWDAContinuedStarted;

static void JVStopWDAProgressTimer(void)
{
  if (JVWDAProgressTimer != nil) {
    dispatch_source_cancel(JVWDAProgressTimer);
    JVWDAProgressTimer = nil;
  }
}

static void JVStartWDAContinuedProcessing(void)
{
  if (JVWDAContinuedStarted) {
    return;
  }
  JVWDAContinuedStarted = YES;
  if (@available(iOS 26.0, *)) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *identifier = [NSString stringWithFormat:@"%@.wda-recovery.%@", bundleIdentifier, NSUUID.UUID.UUIDString.lowercaseString];
    BOOL registered = [BGTaskScheduler.sharedScheduler
      registerForTaskWithIdentifier:identifier
      usingQueue:dispatch_get_main_queue()
      launchHandler:^(__kindof BGTask *task) {
        if (![task isKindOfClass:BGContinuedProcessingTask.class]) {
          [task setTaskCompletedWithSuccess:NO];
          return;
        }
        BGContinuedProcessingTask *continued = (BGContinuedProcessingTask *)task;
        JVWDAContinuedTask = continued;
        continued.progress.totalUnitCount = 17280;
        continued.progress.completedUnitCount = 0;
        __weak BGContinuedProcessingTask *weakContinued = continued;
        continued.expirationHandler = ^{
          dispatch_async(dispatch_get_main_queue(), ^{
            JVStopWDAProgressTimer();
            [weakContinued setTaskCompletedWithSuccess:NO];
            JVWDAContinuedTask = nil;
          });
        };
        JVStopWDAProgressTimer();
        __block int64_t ticks = 0;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
          ticks = MIN((int64_t)17279, ticks + 1);
          continued.progress.completedUnitCount = ticks;
          if (ticks % 360 == 0) {
            NSInteger remaining = MAX(0, 48 - (NSInteger)(ticks / 360));
            [continued updateTitle:@"Jarvis UI control" subtitle:[NSString stringWithFormat:@"Local automation channel · %ldh remaining", (long)remaining]];
          }
        });
        JVWDAProgressTimer = timer;
        dispatch_resume(timer);
        NSLog(@"JARVIS_WDA_CONTINUED_ACTIVE");
      }];
    if (!registered) {
      NSLog(@"JARVIS_WDA_CONTINUED_REGISTER_REJECTED");
      return;
    }
    BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
      initWithIdentifier:identifier
      title:@"Jarvis UI control"
      subtitle:@"Maintaining the local automation channel"];
    request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyQueue;
    request.requiredResources = BGContinuedProcessingTaskRequestResourcesDefault;
    NSError *error = nil;
    BOOL submitted = [BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error];
    NSLog(@"JARVIS_WDA_CONTINUED_SUBMITTED ok=%@ code=%ld", submitted ? @"yes" : @"no", (long)error.code);
  }
}
'''.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wda_root", type=Path)
    args = parser.parse_args()
    test_file = args.wda_root / "WebDriverAgentRunner" / "UITestingUITests.m"
    text = test_file.read_text(encoding="utf-8")
    if MARKER in text or CALL in text:
        raise RuntimeError("continued-processing patch already present")

    xctest_import = "#import <XCTest/XCTest.h>"
    if text.count(xctest_import) != 1:
        raise RuntimeError("unexpected XCTest import count")
    text = text.replace(
        xctest_import,
        xctest_import + "\n#import <BackgroundTasks/BackgroundTasks.h>\n#import <UIKit/UIKit.h>",
        1,
    )

    interface = "@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>"
    fallback = "@interface UITestingUITests : XCTestCase <FBWebServerDelegate>"
    if text.count(interface) != 1:
        raise RuntimeError("UITestingUITests interface anchor missing")
    text = text.replace(interface, f"{SNIPPET}\n\n{fallback}", 1)
    text = text.replace(
        "#import <WebDriverAgentLib/FBFailureProofTestCase.h>",
        "// Jarvis iOS 26 patch: no FBFailureProofTestCase import",
        1,
    )

    implementation = "@implementation UITestingUITests"
    load_method = r'''@implementation UITestingUITests

+ (void)load
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
      JVStartWDAContinuedProcessing();
      return;
    }
    JVWDAForegroundObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:UIApplicationDidBecomeActiveNotification
      object:nil
      queue:NSOperationQueue.mainQueue
      usingBlock:^(NSNotification *notification) {
        (void)notification;
        JVStartWDAContinuedProcessing();
        if (JVWDAForegroundObserver != nil) {
          [NSNotificationCenter.defaultCenter removeObserver:JVWDAForegroundObserver];
          JVWDAForegroundObserver = nil;
        }
      }];
  });
}'''
    if text.count(implementation) != 1:
        raise RuntimeError("UITestingUITests implementation anchor missing")
    text = text.replace(implementation, load_method, 1)

    serving = "  [webServer startServing];"
    if text.count(serving) != 1:
        raise RuntimeError("expected one web server start")
    text = text.replace(serving, f"{CALL}\n{serving}", 1)
    test_file.write_text(text, encoding="utf-8")
    result = test_file.read_text(encoding="utf-8")
    for expected in (MARKER, CALL, fallback, "BGContinuedProcessingTaskRequestSubmissionStrategyQueue"):
        if expected not in result:
            raise RuntimeError(f"post-patch marker missing: {expected}")
    print(f"JARVIS_WDA_CONTINUED_PATCHED file={test_file}")


if __name__ == "__main__":
    main()
