// Jarvis WDA host continued-processing v1.
#import <BackgroundTasks/BackgroundTasks.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const JVIdentifierKey = @"jarvis.wda.host.identifier";
static BGContinuedProcessingTask *JVTask;
static dispatch_source_t JVTimer;
static id JVForegroundObserver;
static BOOL JVSubmissionInFlight;
static NSInteger JVAttempts;

static void JVStopTimer(void)
{
  if (JVTimer != nil) {
    dispatch_source_cancel(JVTimer);
    JVTimer = nil;
  }
}

static void JVBeginTask(BGTask *task)
{
  if (@available(iOS 26.0, *)) {
    if (![task isKindOfClass:BGContinuedProcessingTask.class]) {
      [task setTaskCompletedWithSuccess:NO];
      return;
    }
    BGContinuedProcessingTask *continued = (BGContinuedProcessingTask *)task;
    JVTask = continued;
    JVSubmissionInFlight = NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"jarvis.wda.continued.active"];
    continued.progress.totalUnitCount = 17280;
    continued.progress.completedUnitCount = 0;
    __weak BGContinuedProcessingTask *weakContinued = continued;
    continued.expirationHandler = ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        JVStopTimer();
        [weakContinued setTaskCompletedWithSuccess:NO];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"jarvis.wda.continued.active"];
        JVTask = nil;
        JVSubmissionInFlight = NO;
      });
    };
    __block int64_t ticks = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
      ticks = MIN((int64_t)17279, ticks + 1);
      continued.progress.completedUnitCount = ticks;
      if (ticks % 360 == 0) {
        NSInteger remaining = MAX(0, 48 - (NSInteger)(ticks / 360));
        [continued updateTitle:@"Jarvis UI control"
                      subtitle:[NSString stringWithFormat:@"Local automation channel · %ldh remaining", (long)remaining]];
      }
    });
    JVTimer = timer;
    dispatch_resume(timer);
    NSLog(@"JARVIS_WDA_HOST_CONTINUED_ACTIVE");
  }
}

static BOOL JVRegisterIdentifier(NSString *identifier)
{
  if (@available(iOS 26.0, *)) {
    BOOL registered = [BGTaskScheduler.sharedScheduler
      registerForTaskWithIdentifier:identifier
      usingQueue:dispatch_get_main_queue()
      launchHandler:^(__kindof BGTask *task) {
        JVBeginTask(task);
      }];
    [NSUserDefaults.standardUserDefaults setBool:registered forKey:@"jarvis.wda.continued.registered"];
    return registered;
  }
  return NO;
}

static void JVSubmitFromForeground(void)
{
  if (@available(iOS 26.0, *)) {
    if (JVTask != nil || JVSubmissionInFlight) {
      return;
    }
    JVAttempts += 1;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:JVAttempts forKey:@"jarvis.wda.continued.attempts"];
    [defaults setInteger:UIApplication.sharedApplication.applicationState forKey:@"jarvis.wda.continued.submitState"];

    NSString *oldIdentifier = [defaults stringForKey:JVIdentifierKey];
    if (oldIdentifier != nil) {
      [BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:oldIdentifier];
    }
    NSString *identifier = [NSString stringWithFormat:@"%@.wda-recovery.%@",
      NSBundle.mainBundle.bundleIdentifier,
      NSUUID.UUID.UUIDString.lowercaseString];
    if (!JVRegisterIdentifier(identifier)) {
      [defaults setBool:NO forKey:@"jarvis.wda.continued.submitted"];
      [defaults setInteger:BGTaskSchedulerErrorCodeNotPermitted forKey:@"jarvis.wda.continued.error"];
      return;
    }
    [defaults setObject:identifier forKey:JVIdentifierKey];
    BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
      initWithIdentifier:identifier
      title:@"Jarvis UI control"
      subtitle:@"Maintaining the local automation channel"];
    request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
    request.requiredResources = BGContinuedProcessingTaskRequestResourcesDefault;
    NSError *error = nil;
    BOOL submitted = [BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error];
    JVSubmissionInFlight = submitted;
    [defaults setBool:submitted forKey:@"jarvis.wda.continued.submitted"];
    [defaults setInteger:error.code forKey:@"jarvis.wda.continued.error"];
    NSLog(@"JARVIS_WDA_HOST_CONTINUED_SUBMITTED ok=%@ code=%ld", submitted ? @"yes" : @"no", (long)error.code);
  }
}

__attribute__((constructor))
static void JVInstallHostContinuation(void)
{
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setBool:YES forKey:@"jarvis.wda.continued.hook"];
  [defaults setBool:NO forKey:@"jarvis.wda.continued.active"];
  [defaults setBool:NO forKey:@"jarvis.wda.continued.submitted"];
  [defaults setInteger:0 forKey:@"jarvis.wda.continued.error"];
  [defaults setInteger:0 forKey:@"jarvis.wda.continued.attempts"];

  if (@available(iOS 26.0, *)) {
    NSString *pendingIdentifier = [defaults stringForKey:JVIdentifierKey];
    if (pendingIdentifier != nil) {
      JVRegisterIdentifier(pendingIdentifier);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [defaults setInteger:UIApplication.sharedApplication.applicationState forKey:@"jarvis.wda.continued.appState"];
      if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        JVSubmitFromForeground();
      }
      JVForegroundObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
          (void)notification;
          JVSubmitFromForeground();
        }];
    });
  }
}
