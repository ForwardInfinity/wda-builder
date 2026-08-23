// Jarvis reverse-agent phase 1. This block is injected into UITestingUITests.m
// by patch_wda_reverse_agent.py so no Xcode project-file mutation is needed.

static NSString *const JVAgentBaseURL = @"https://workbox.tailfd8ac6.ts.net";
static NSString *const JVAgentTokenKey = @"JarvisReverseAgentTokenV1";
static NSString *const JVAgentDeviceKey = @"JarvisReverseAgentDeviceV1";
static const NSTimeInterval JVAgentInterval = 5.0;

@interface JVReverseAgent : NSObject
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL inFlight;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL reportedHealthy;
@end

@implementation JVReverseAgent

+ (instancetype)sharedAgent
{
  static JVReverseAgent *agent;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    agent = [[JVReverseAgent alloc] init];
  });
  return agent;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("net.jarvis.reverse-agent", DISPATCH_QUEUE_SERIAL);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 10.0;
    configuration.timeoutIntervalForResource = 15.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.allowsCellularAccess = YES;
    configuration.HTTPShouldSetCookies = NO;
    if (@available(iOS 11.0, *)) {
      configuration.waitsForConnectivity = YES;
    }
    _session = [NSURLSession sessionWithConfiguration:configuration];
  }
  return self;
}

- (NSString *)deviceID
{
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *value = [defaults stringForKey:JVAgentDeviceKey];
  if (value.length >= 8) {
    return value;
  }
  value = NSUUID.UUID.UUIDString;
  [defaults setObject:value forKey:JVAgentDeviceKey];
  return value;
}

- (NSString *)token
{
  return [NSUserDefaults.standardUserDefaults stringForKey:JVAgentTokenKey];
}

- (void)start
{
  dispatch_async(self.queue, ^{
    if (self.started) {
      return;
    }
    self.started = YES;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(
      self.timer,
      dispatch_time(DISPATCH_TIME_NOW, 0),
      (uint64_t)(JVAgentInterval * NSEC_PER_SEC),
      (uint64_t)(0.5 * NSEC_PER_SEC)
    );
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
      [weakSelf tick];
    });
    dispatch_resume(self.timer);
    NSLog(@"JarvisAgent phase1 started");
  });
}

- (NSDictionary *)heartbeatPayload
{
  NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
  NSString *os = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"unknown";
  return @{
    @"device_id": self.deviceID,
    @"protocol": @1,
    @"agent_version": @"phase1-1",
    @"uptime": @(NSProcessInfo.processInfo.systemUptime),
    @"bundle": bundle,
    @"os": os,
  };
}

- (void)tick
{
  if (self.inFlight) {
    return;
  }
  NSString *token = self.token;
  NSDictionary *payload;
  NSString *path;
  if (token.length == 0) {
    path = @"/v1/enroll";
    payload = @{
      @"client": @"jarvis-wda",
      @"protocol": @1,
      @"device_id": self.deviceID,
    };
  } else {
    path = @"/v1/heartbeat";
    payload = self.heartbeatPayload;
  }

  NSError *jsonError = nil;
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
  if (body == nil || jsonError != nil) {
    return;
  }
  NSURL *url = [NSURL URLWithString:[JVAgentBaseURL stringByAppendingString:path]];
  if (url == nil) {
    return;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
  if (token.length > 0) {
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
  }

  self.inFlight = YES;
  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      dispatch_async(weakSelf.queue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
          return;
        }
        self.inFlight = NO;
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (error != nil || status < 200 || status >= 300) {
          if (self.reportedHealthy) {
            NSLog(@"JarvisAgent heartbeat unavailable status=%ld error=%@", (long)status, error.domain ?: @"none");
          }
          self.reportedHealthy = NO;
          return;
        }
        if (token.length == 0) {
          NSDictionary *value = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          NSString *issuedToken = [value isKindOfClass:NSDictionary.class] ? value[@"token"] : nil;
          if ([issuedToken isKindOfClass:NSString.class] && issuedToken.length >= 40) {
            [NSUserDefaults.standardUserDefaults setObject:issuedToken forKey:JVAgentTokenKey];
            NSLog(@"JarvisAgent enrollment complete");
            [self tick];
          }
          return;
        }
        if (!self.reportedHealthy) {
          NSLog(@"JarvisAgent outbound heartbeat healthy");
        }
        self.reportedHealthy = YES;
      });
    }];
  [task resume];
}

@end
