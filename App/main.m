// CleanTA launcher: CarPlay UI is hosted by the injected CleanTA tweak.
// No iPhone window is created. Retry the request briefly if CarBridge backgrounds
// this launcher before the CarPlay overlay has received it.
#import <UIKit/UIKit.h>
#import <notify.h>

static const char *CTShowNote = "com.sushibta.cleanta.show.v1";
static const char *CTShowAck = "com.sushibta.cleanta.show.ack.v1";

@interface CTAppDelegate : UIResponder <UIApplicationDelegate> {
    int _ackToken;
}
@property(nonatomic,assign) NSUInteger requestGeneration;
@property(nonatomic,strong) dispatch_source_t retryTimer;
@property(nonatomic,assign) UIBackgroundTaskIdentifier retryTask;
@property(nonatomic,assign) NSTimeInterval retryDeadline;
@property(nonatomic,assign) BOOL requestAcknowledged;
@end

@implementation CTAppDelegate
- (void)stopPanelRetries {
    if (self.retryTimer) {
        dispatch_source_cancel(self.retryTimer);
        self.retryTimer = nil;
    }
    if (self.retryTask != UIBackgroundTaskInvalid) {
        UIBackgroundTaskIdentifier task = self.retryTask;
        self.retryTask = UIBackgroundTaskInvalid;
        [UIApplication.sharedApplication endBackgroundTask:task];
    }
}
- (void)requestPanel {
    [self stopPanelRetries];
    self.requestAcknowledged = NO;
    self.retryDeadline = NSProcessInfo.processInfo.systemUptime + 12.0;
    NSUInteger generation = ++self.requestGeneration;
    __weak typeof(self) weakSelf = self;
    self.retryTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"CleanTA CarPlay panel request"
        expirationHandler:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self && generation == self.requestGeneration) [self stopPanelRetries];
        }];
    notify_post(CTShowNote);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    self.retryTimer = timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                              500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.requestGeneration || self.requestAcknowledged ||
            NSProcessInfo.processInfo.systemUptime >= self.retryDeadline) {
            [self stopPanelRetries];
            return;
        }
        notify_post(CTShowNote);
    });
    dispatch_resume(timer);
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.retryTask = UIBackgroundTaskInvalid;
    _ackToken = -1;
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(CTShowAck, &_ackToken, dispatch_get_main_queue(), ^(int token) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.requestAcknowledged = YES;
        [self stopPanelRetries];
    });
    [self requestPanel];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application { [self requestPanel]; }
- (void)applicationWillEnterForeground:(UIApplication *)application { [self requestPanel]; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CTAppDelegate.class)); }
}
