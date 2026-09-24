// CleanTA launcher: CarPlay UI is hosted by the injected CleanTA tweak.
// Do not create an iPhone UIWindow; only request the CarPlay panel.
#import <UIKit/UIKit.h>
#import <notify.h>

@interface CTAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,assign) NSUInteger requestGeneration;
@end

@implementation CTAppDelegate
- (void)requestPanel {
    NSUInteger generation = ++self.requestGeneration;
    notify_post("com.sushibta.cleanta.show.v1");
    // CarBridge can start this launcher before the CarPlay tweak finishes attaching
    // its overlay. Retry briefly so the request survives that startup race.
    for (NSNumber *delay in @[@0.35, @0.8, @1.3, @1.9]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.requestGeneration ||
                UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            notify_post("com.sushibta.cleanta.show.v1");
        });
    }
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    [self requestPanel];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application { [self requestPanel]; }
- (void)applicationWillEnterForeground:(UIApplication *)application { [self requestPanel]; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CTAppDelegate.class)); }
}
