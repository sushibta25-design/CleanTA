#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <unistd.h>
#import "CTProtocol.h"

static const char *CTRequest = "com.sushibta.cleanta.close.v1";
static const char *CTReply = "com.sushibta.cleanta.result.v1";
static int requestToken = -1, replyToken = -1;
static BOOL serverBusy;
static id CTGet(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    return [object respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(object,sel) : nil;
}
static id CTService(void) { return CTGet(NSClassFromString(@"FBSSystemService"), @"sharedService"); }
static int CTPid(NSString *bundle) {
    id service = CTService(); SEL sel = NSSelectorFromString(@"pidForApplication:");
    if (![service respondsToSelector:sel]) return -1;
    return ((int(*)(id,SEL,id))objc_msgSend)(service,sel,bundle);
}
static NSArray *CTProxies(void) {
    id ws = CTGet(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    id apps = CTGet(ws,@"allInstalledApplications");
    return [apps isKindOfClass:NSArray.class] ? apps : nil;
}
static BOOL CTAllowed(id proxy) {
    NSString *bundle = CTGet(proxy,@"applicationIdentifier");
    if (![bundle isKindOfClass:NSString.class] || !bundle.length) return NO;
    // Apple system processes are never targets, even if their proxy type changes.
    if ([bundle hasPrefix:@"com.apple."]) {
        return [@[@"com.apple.Maps", @"com.apple.Music", @"com.apple.podcasts"] containsObject:bundle];
    }
    return [CTGet(proxy,@"applicationType") isEqual:@"User"];
}
static void CTRespond(uint64_t key, unsigned result) {
    if (replyToken < 0) return;
    if (notify_set_state(replyToken, key | result) == NOTIFY_STATUS_OK) notify_post(CTReply);
}
static void CTHandleRequest(void) {
    uint64_t key = 0;
    if (notify_get_state(requestToken,&key) != NOTIFY_STATUS_OK || !CTValidKey(key)) return;
    if (serverBusy) { CTRespond(key,3); return; }
    @try {
        NSString *target = nil;
        for (id proxy in CTProxies()) {
            if (!CTAllowed(proxy)) continue;
            NSString *bundle = CTGet(proxy,@"applicationIdentifier");
            int pid = CTPid(bundle);
            if (pid > 1 && pid != getpid() && CTKey(bundle.UTF8String,pid) == key) {
                if (target) { CTRespond(key,3); return; }
                target = bundle;
            }
        }
        if (!target) { CTRespond(key,3); return; }
        id service = CTService();
        SEL terminate = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
        if (![service respondsToSelector:terminate]) { CTRespond(key,3); return; }
        serverBusy = YES;
        ((void(*)(id,SEL,id,long long,BOOL,id))objc_msgSend)(service,terminate,target,1,NO,@"CleanTA: user requested close");
        // A single delayed check, only following a user request. No idle polling.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
            unsigned result = 2;
            @try { result = CTPid(target) == 0 ? 1 : 2; } @catch (NSException *e) { result = 3; }
            CTRespond(key,result); serverBusy = NO;
        });
    } @catch (NSException *e) { serverBusy = NO; CTRespond(key,3); }
}

@interface CTWindow : UIWindow
@property(nonatomic,weak) UIView *entry;
@property(nonatomic,assign) BOOL expanded;
- (void)refreshGeometry;
@end
@implementation CTWindow
- (void)refreshGeometry {
    CGRect full = self.screen.coordinateSpace.bounds;
    if (CGRectIsEmpty(full) || CGRectIsInfinite(full)) return;
    if (!CGRectEqualToRect(self.frame,full)) self.frame = full;
    [self.rootViewController.view setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Screen geometry, never the bounds of a dock or app-host window.
    CGRect full = self.screen.coordinateSpace.bounds;
    if (!CGRectIsEmpty(full) && !CGRectIsInfinite(full) && !CGRectEqualToRect(self.frame,full)) self.frame = full;
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    if (!self.expanded && ![self.entry pointInside:[self.entry convertPoint:p fromView:self] withEvent:event]) return nil;
    return [super hitTest:p withEvent:event];
}
@end

@interface CTController : UIViewController <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,strong) UIButton *entry;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,copy) NSArray *rows;
@property(nonatomic,assign) uint64_t pending;
@property(nonatomic,assign) NSUInteger generation;
@property(nonatomic,assign) BOOL loading;
- (void)receiveResult:(uint64_t)result;
@end
static CTWindow *overlay;
static CTController *controller;

@implementation CTController
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    b.backgroundColor = UIColor.clearColor;
    b.tintColor = UIColor.whiteColor;
    b.titleLabel.numberOfLines = 1;
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.8;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.clearColor; self.rows = @[];
    self.entry = [self button:@"CT" action:@selector(openPanel)];
    self.entry.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    self.entry.tintColor = UIColor.systemTealColor; self.entry.layer.cornerRadius = 20;
    self.entry.accessibilityLabel = @"Mở CleanTA";
    [self.entry addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.view addSubview:self.entry];
    self.panel = [UIView new]; self.panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.panel.hidden = YES; [self.view addSubview:self.panel];
    UIButton *back = [self button:@"Xong" action:@selector(closePanel)]; back.tag = 1;
    UIButton *reload = [self button:@"Làm mới" action:@selector(reloadApps)]; reload.tag = 2;
    [self.panel addSubview:back]; [self.panel addSubview:reload];
    UILabel *title = [UILabel new]; title.text = @"CleanTA"; title.textAlignment = NSTextAlignmentCenter;
    title.textColor = UIColor.whiteColor; title.font = [UIFont boldSystemFontOfSize:20]; title.tag = 3; [self.panel addSubview:title];
    self.status = [UILabel new]; self.status.font = [UIFont systemFontOfSize:14];
    self.status.textColor = UIColor.lightGrayColor; self.status.numberOfLines = 2; self.status.textAlignment = NSTextAlignmentCenter;
    [self.panel addSubview:self.status];
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.table.delegate = self; self.table.dataSource = self; self.table.rowHeight = 60;
    [self.panel addSubview:self.table];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGRect bounds = self.view.bounds;
    // This is our independent full-screen surface, not a CarPlay dock scene.
    CGRect safe = CGRectInset(bounds,8,8);
    if (CGRectIsEmpty(self.entry.frame)) self.entry.frame = CGRectMake(CGRectGetMidX(safe)-22,CGRectGetMinY(safe)+6,44,44);
    CGPoint c = self.entry.center;
    c.x = MAX(CGRectGetMinX(safe)+22,MIN(c.x,CGRectGetMaxX(safe)-22));
    c.y = MAX(CGRectGetMinY(safe)+22,MIN(c.y,CGRectGetMaxY(safe)-22)); self.entry.center = c;
    self.panel.frame = bounds;
    CGFloat x = CGRectGetMinX(safe), y = CGRectGetMinY(safe), w = CGRectGetWidth(safe);
    [self.panel viewWithTag:1].frame = CGRectMake(x,y,76,44);
    [self.panel viewWithTag:2].frame = CGRectMake(x+w-100,y,100,44);
    [self.panel viewWithTag:3].frame = CGRectMake(x+76,y,MAX(0,w-176),44);
    self.status.frame = CGRectMake(x+8,y+44,w-16,42);
    self.table.frame = CGRectMake(x,y+86,w,MAX(0,CGRectGetHeight(safe)-86));
}
- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.view];
    self.entry.center = CGPointMake(self.entry.center.x+d.x,self.entry.center.y+d.y);
    [g setTranslation:CGPointZero inView:self.view]; [self.view setNeedsLayout];
}
- (void)openPanel { [overlay refreshGeometry]; [self.view layoutIfNeeded]; overlay.expanded = YES; self.panel.hidden = NO; [self reloadApps]; }
- (void)closePanel { self.panel.hidden = YES; overlay.expanded = NO; }
- (void)reloadApps {
    if (self.pending || self.loading) return;
    self.loading = YES; self.status.text = @"Đang kiểm tra ứng dụng…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSMutableArray *rows = [NSMutableArray new]; NSString *error = nil;
        @try {
            NSArray *proxies = CTProxies();
            if (!proxies || ![CTService() respondsToSelector:NSSelectorFromString(@"pidForApplication:")]) {
                error = @"iOS này chưa cho CleanTA đọc danh sách tiến trình.";
            } else for (id proxy in proxies) {
                if (!CTAllowed(proxy)) continue;
                NSString *bundle = CTGet(proxy,@"applicationIdentifier"); int pid = CTPid(bundle);
                if (pid <= 1) continue;
                NSString *name = CTGet(proxy,@"localizedName");
                [rows addObject:@{@"bundle":bundle,@"pid":@(pid),@"name":name ?: bundle}];
            }
            [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
                return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
            }];
        } @catch(NSException *e) { error = @"Không đọc được ứng dụng. Cần kiểm tra tương thích iOS."; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO; self.rows = rows; [self.table reloadData];
            self.status.text = error ?: (rows.count ? @"Chọn ứng dụng để đóng hẳn trên iPhone và CarPlay." : @"Chưa tìm thấy ứng dụng đang chạy có thể đóng. Thử mở VML rồi làm mới.");
        });
    });
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    cell.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    cell.textLabel.textColor = UIColor.whiteColor; cell.detailTextLabel.textColor = UIColor.lightGrayColor;
    NSDictionary *row = self.rows[index.row]; cell.textLabel.text = row[@"name"];
    cell.detailTextLabel.text = row[@"bundle"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES]; if (self.pending || self.loading) return;
    NSDictionary *row = self.rows[index.row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[@"Đóng " stringByAppendingString:row[@"name"]]
        message:@"Ứng dụng sẽ dừng trên cả iPhone và CarPlay." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng ứng dụng" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self closeApp:row]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)closeApp:(NSDictionary *)row {
    if (requestToken < 0 || replyToken < 0) { self.status.text = @"Không kết nối được CleanTA. Thử respring."; return; }
    uint64_t key = CTKey([row[@"bundle"] UTF8String],[row[@"pid"] intValue]);
    self.pending = key; NSUInteger generation = ++self.generation;
    self.status.text = @"Đang đóng và kiểm tra lại…";
    if (notify_set_state(requestToken,key) != NOTIFY_STATUS_OK || notify_post(CTRequest) != NOTIFY_STATUS_OK) {
        self.pending = 0; self.status.text = @"Không gửi được yêu cầu đóng."; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        if (self.pending == key && self.generation == generation) {
            self.pending = 0; self.status.text = @"Chưa nhận được phản hồi. Bấm Làm mới để kiểm tra.";
        }
    });
}
- (void)receiveResult:(uint64_t)result {
    if (!self.pending || (result & ~UINT64_C(3)) != self.pending || !(result & 3)) return;
    uint64_t key = self.pending; self.pending = 0;
    if ((result & 3) == 1) {
        self.rows = [self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings) {
            return CTKey([row[@"bundle"] UTF8String],[row[@"pid"] intValue]) != key;
        }]]; [self.table reloadData]; self.status.text = @"Đã kiểm tra: ứng dụng đã dừng.";
    } else self.status.text = (result & 3) == 2 ? @"Ứng dụng vẫn chạy hoặc tự mở lại. Bấm Làm mới." : @"Chưa đóng được: tiến trình đã đổi hoặc iOS chưa hỗ trợ.";
}
@end

static void CTAttach(UIWindow *host) {
    if (!host || [host isKindOfClass:CTWindow.class] || host.hidden || host.windowLevel != UIWindowLevelNormal || !host.rootViewController) return;
    UIScreen *screen = host.screen;
    if (!screen || CGRectIsEmpty(screen.coordinateSpace.bounds)) return;
    if (overlay) {
        // Keep a single overlay; prefer an external display if it appears later.
        if (overlay.screen != screen && overlay.screen == UIScreen.mainScreen && screen != UIScreen.mainScreen) {
            overlay.hidden = YES; overlay.screen = screen;
            [overlay refreshGeometry]; overlay.hidden = NO;
        }
        return;
    }
    controller = [CTController new];
    // CarPlayApp can expose the dock as its first UIWindowScene. Attaching to
    // that scene clips the entire UI to the dock, even with a larger frame.
    // A jailbreak overlay is bound directly to the same UIScreen instead.
    overlay = [[CTWindow alloc] initWithFrame:screen.coordinateSpace.bounds];
    overlay.screen = screen;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    overlay.windowLevel = UIWindowLevelAlert + 100; overlay.rootViewController = controller;
    [controller loadViewIfNeeded]; overlay.entry = controller.entry;
    [overlay refreshGeometry]; overlay.hidden = NO;
}
__attribute__((constructor)) static void CTInit(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY);
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY);
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if ([bundle isEqual:@"com.apple.springboard"]) {
            if (notify_register_check(CTReply,&replyToken) != NOTIFY_STATUS_OK) replyToken = -1;
            if (notify_register_dispatch(CTRequest,&requestToken,dispatch_get_main_queue(),^(int token) { CTHandleRequest(); }) != NOTIFY_STATUS_OK) requestToken = -1;
        } else if ([bundle isEqual:@"com.apple.CarPlayApp"]) {
            if (notify_register_check(CTRequest,&requestToken) != NOTIFY_STATUS_OK) requestToken = -1;
            if (notify_register_dispatch(CTReply,&replyToken,dispatch_get_main_queue(),^(int token) {
                uint64_t result = 0; if (notify_get_state(token,&result) == NOTIFY_STATUS_OK) [controller receiveResult:result];
            }) != NOTIFY_STATUS_OK) replyToken = -1;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
                [nc addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { CTAttach(n.object); }];
                [nc addObserverForName:UIScreenDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                    if (overlay.screen == n.object) { overlay.hidden = YES; overlay.rootViewController = nil; overlay = nil; controller = nil; }
                }];
                [nc addObserverForName:UIScreenModeDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                    if (overlay.screen == n.object) [overlay refreshGeometry];
                }];
                [nc addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                    for (UIWindow *window in UIApplication.sharedApplication.windows) CTAttach(window);
                    [overlay refreshGeometry];
                }];
                for (UIWindow *window in UIApplication.sharedApplication.windows) CTAttach(window);
            });
        }
    }
}
