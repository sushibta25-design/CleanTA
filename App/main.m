// CleanTA.app — app nhỏ để có icon CleanTA trên Home CarPlay (qua tweak bridge).
// Khi được mở, app báo cho tweak trong CarPlay hiện bảng CleanTA.
// Bấm "Xong" trong bảng, tweak sẽ kết thúc app này để CarPlay về Home.
#import <UIKit/UIKit.h>
#import <notify.h>

@interface CTAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation CTAppDelegate
- (void)requestPanel { notify_post("com.sushibta.cleanta.show.v1"); }
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.33 blue:0.42 alpha:1];
    UILabel *label = [UILabel new];
    label.text = @"CleanTA\n\nMở trên màn hình CarPlay để đóng ứng dụng đang chạy.";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont boldSystemFontOfSize:20];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [root.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:root.view.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.view.leadingAnchor constant:24],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:root.view.trailingAnchor constant:-24]
    ]];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    [self requestPanel];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application { [self requestPanel]; }
- (void)applicationWillEnterForeground:(UIApplication *)application { [self requestPanel]; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CTAppDelegate.class)); }
}
