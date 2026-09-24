// CleanTA 1.0.0 — đóng app đang chạy từ màn hình CarPlay.
// SpringBoard: server kết thúc app qua RunningBoard.
// CarPlayApp : giao diện + chặn CarPlay tự mở lại app dẫn đường.
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import "CTProtocol.h"
#import "CTUtil.h"
#import "CTGuard.h"

static const char *CTRequest = "com.sushibta.cleanta.close.v1";
static const char *CTReply = "com.sushibta.cleanta.result.v1";
static const char *CTShowNote = "com.sushibta.cleanta.show.v1";
static const char *CTShowAck = "com.sushibta.cleanta.show.ack.v1";
static int requestToken = -1, replyToken = -1, showToken = -1;
static int sampleTokens[2] = {-1,-1};
static BOOL serverBusy;
static NSTimeInterval CTStubMuteUntil; // bỏ qua kích hoạt icon ngay sau khi bấm Xong

#pragma mark - Tiến trình

// kill(pid, 0) chỉ thăm dò tồn tại, không gửi tín hiệu.
static unsigned CTExists(int pid) {
    if (pid <= 1) return 2;
    if (kill(pid,0) == 0) return 1;
    return errno == ESRCH ? 0 : (errno == EPERM ? 1 : 2);
}
static id CTGet(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    return [object respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(object,sel) : nil;
}
static BOOL CTInSpringBoard(void) {
    static BOOL value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]; });
    return value;
}
static id CTService(void) { return CTGet(NSClassFromString(@"FBSSystemService"), @"sharedService"); }
// SpringBoard đọc PID trong tiến trình hoặc hỏi runningboardd (không XPC ngược vào chính nó).
static int CTServerPid(NSString *bundle) {
    id controller = CTGet(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if ([controller respondsToSelector:appSel]) {
        id app = ((id(*)(id,SEL,id))objc_msgSend)(controller,appSel,bundle);
        id state = CTGet(app,@"processState");
        SEL pidSel = NSSelectorFromString(@"pid");
        if ([state respondsToSelector:pidSel]) {
            int pid = ((int(*)(id,SEL))objc_msgSend)(state,pidSel);
            if (pid > 1) return pid;
        }
    }
    Class predCls = NSClassFromString(@"RBSProcessPredicate"), handleCls = NSClassFromString(@"RBSProcessHandle");
    SEL predSel = NSSelectorFromString(@"predicateMatchingBundleIdentifier:");
    SEL handleSel = NSSelectorFromString(@"handleForPredicate:error:");
    if (![predCls respondsToSelector:predSel] || ![handleCls respondsToSelector:handleSel]) return 0;
    id pred = ((id(*)(id,SEL,id))objc_msgSend)(predCls,predSel,bundle);
    NSError *err = nil;
    id handle = ((id(*)(id,SEL,id,NSError **))objc_msgSend)(handleCls,handleSel,pred,&err);
    for (NSString *name in @[@"rbs_pid", @"pid"]) {
        SEL sel = NSSelectorFromString(name);
        if ([handle respondsToSelector:sel]) { int pid = ((int(*)(id,SEL))objc_msgSend)(handle,sel); return pid > 1 ? pid : 0; }
    }
    return 0;
}
static int CTPid(NSString *bundle) {
    if (CTInSpringBoard()) return CTServerPid(bundle);
    id service = CTService(); SEL sel = NSSelectorFromString(@"pidForApplication:");
    if (![service respondsToSelector:sel]) return -1;
    return ((int(*)(id,SEL,id))objc_msgSend)(service,sel,bundle);
}
// Kết thúc qua RunningBoard (SpringBoard có entitlement terminateprocess).
static BOOL CTTerminate(NSString *bundle) {
    Class ctxCls = NSClassFromString(@"RBSTerminateContext"), reqCls = NSClassFromString(@"RBSTerminateRequest");
    Class predCls = NSClassFromString(@"RBSProcessPredicate");
    SEL ctxSel = NSSelectorFromString(@"defaultContextWithExplanation:");
    SEL predSel = NSSelectorFromString(@"predicateMatchingBundleIdentifier:");
    SEL initSel = NSSelectorFromString(@"initWithPredicate:context:");
    SEL execSel = NSSelectorFromString(@"execute:");
    if (![ctxCls respondsToSelector:ctxSel] || ![predCls respondsToSelector:predSel] || ![reqCls instancesRespondToSelector:initSel]) {
        return NO;
    }
    id ctx = ((id(*)(id,SEL,id))objc_msgSend)(ctxCls,ctxSel,@"CleanTA: user requested close");
    @try {
        [ctx setValue:@0 forKey:@"reportType"];
        [ctx setValue:@(0xbaadca11ULL) forKey:@"exceptionCode"];
        [ctx setValue:@40 forKey:@"maximumTerminationResistance"];
    } @catch (__unused NSException *e) {}
    id pred = ((id(*)(id,SEL,id))objc_msgSend)(predCls,predSel,bundle);
    id req = ((id(*)(id,SEL,id,id))objc_msgSend)([reqCls alloc],initSel,pred,ctx);
    if (![req respondsToSelector:execSel]) return NO;
    NSError *err = nil;
    return ((BOOL(*)(id,SEL,NSError **))objc_msgSend)(req,execSel,&err);
}
// Icon app (API riêng của UIKit), thu về 44pt bo góc. Không có thì dùng biểu tượng mặc định.
static UIImage *CTAppIcon(NSString *bundle) {
    UIImage *icon = nil;
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:sel]) {
        @try { icon = ((UIImage *(*)(id,SEL,id,int,CGFloat))objc_msgSend)(UIImage.class,sel,bundle,2,(CGFloat)3.0); }
        @catch (__unused NSException *e) {}
    }
    if (!icon) icon = [UIImage systemImageNamed:@"app.fill"];
    if (!icon) return nil;
    CGSize size = CGSizeMake(44,44);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,44,44) cornerRadius:10] addClip];
        [icon drawInRect:CGRectMake(0,0,44,44)];
    }];
}
static NSArray *CTProxies(void) {
    id ws = CTGet(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    id apps = CTGet(ws,@"allInstalledApplications");
    return [apps isKindOfClass:NSArray.class] ? apps : nil;
}
// App người dùng + Maps/Music/Podcasts của Apple. Không bao giờ đóng tiến trình hệ thống.
static BOOL CTAllowed(id proxy) {
    NSString *bundle = CTGet(proxy,@"applicationIdentifier");
    if (![bundle isKindOfClass:NSString.class] || !bundle.length) return NO;
    if ([bundle isEqual:CTStubBundle]) return YES;
    if ([bundle hasPrefix:@"com.apple."])
        return [@[@"com.apple.Maps", @"com.apple.Music", @"com.apple.podcasts"] containsObject:bundle];
    return [CTGet(proxy,@"applicationType") isEqual:@"User"];
}

#pragma mark - Server (SpringBoard)

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
        serverBusy = YES;
        if (!CTTerminate(target)) {
            id service = CTService();
            SEL terminate = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
            if ([service respondsToSelector:terminate])
                ((void(*)(id,SEL,id,long long,BOOL,id))objc_msgSend)(service,terminate,target,1,NO,@"CleanTA: user requested close");
        }
        int original = (uint32_t)(key >> 2);
        for (int i = 0; i < 2; ++i) {
            if (sampleTokens[i] >= 0) notify_set_state(sampleTokens[i],0);
            int slot = i;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(i == 0 ? 1 : 3) * NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                uint64_t sample = 0; unsigned result = 2;
                @try {
                    int pid = CTPid(target);
                    sample = CTMakeSample(pid,CTExists(original),pid > 1 ? CTExists(pid) : 2);
                    if (CTSampleStopped(sample)) result = 1;
                } @catch (__unused NSException *e) { result = 3; }
                if (sampleTokens[slot] >= 0) notify_set_state(sampleTokens[slot],sample);
                if (slot == 1) { CTRespond(key,result); serverBusy = NO; }
            });
        }
    } @catch (__unused NSException *e) { serverBusy = NO; CTRespond(key,3); }
}

#pragma mark - Giao diện (CarPlayApp)

@interface CTWindow : UIWindow
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
    CGRect full = self.screen.coordinateSpace.bounds;
    if (!CGRectIsEmpty(full) && !CGRectIsInfinite(full) && !CGRectEqualToRect(self.frame,full)) self.frame = full;
}
// Khi bảng đóng, mọi thao tác chạm xuyên qua CarPlay.
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    if (!self.expanded) return nil;
    return [super hitTest:p withEvent:event];
}
@end

@interface CTController : UIViewController <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,strong) UIButton *doneButton, *closeAllButton;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *titleLabel, *status;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,copy) NSArray<NSDictionary *> *rows;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic,copy) NSDictionary *closingRow;
@property(nonatomic,assign) uint64_t pending;
@property(nonatomic,assign) NSUInteger generation, retries, queueTotal, queueDone;
@property(nonatomic,assign) BOOL loading, dismissStubWhenIdle;
@property(nonatomic,assign) NSTimeInterval stubKillAt;
@property(nonatomic,readonly) BOOL busy;
- (void)openPanel;
- (void)receiveResult:(uint64_t)result;
@end
static CTWindow *overlay;
static CTController *controller;
static BOOL pendingShowPanel;
static void CTShowPanel(void);

@implementation CTController
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.75;
    b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    b.tintColor = UIColor.whiteColor;
    b.layer.cornerRadius = 12;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.rows = @[]; self.queue = [NSMutableArray new];
    self.panel = [UIView new];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.panel.hidden = YES;
    [self.view addSubview:self.panel];
    self.doneButton = [self button:@"Xong" action:@selector(closePanel)];
    self.closeAllButton = [self button:@"Đóng tất cả" action:@selector(closeAll)];
    self.closeAllButton.backgroundColor = [UIColor colorWithRed:0.78 green:0.20 blue:0.20 alpha:1];
    self.titleLabel = [UILabel new];
    self.titleLabel.text = @"CleanTA";
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.status = [UILabel new];
    self.status.font = [UIFont systemFontOfSize:15];
    self.status.textColor = UIColor.lightGrayColor;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 2;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.backgroundColor = self.panel.backgroundColor;
    self.table.separatorColor = [UIColor colorWithWhite:0.25 alpha:1];
    self.table.rowHeight = 68;
    self.table.delegate = self; self.table.dataSource = self;
    UIRefreshControl *refresh = [UIRefreshControl new];
    refresh.tintColor = UIColor.lightGrayColor;
    [refresh addTarget:self action:@selector(pullRefresh:) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = refresh;
    for (UIView *v in @[self.doneButton,self.closeAllButton,self.titleLabel,self.status,self.table]) [self.panel addSubview:v];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds, safe = CGRectInset(bounds,10,8);
    self.panel.frame = bounds;
    CGFloat x = CGRectGetMinX(safe), y = CGRectGetMinY(safe), w = CGRectGetWidth(safe);
    self.doneButton.frame = CGRectMake(x,y,96,46);
    self.closeAllButton.frame = CGRectMake(x+w-150,y,150,46);
    self.titleLabel.frame = CGRectMake(x+104,y,MAX(0,w-262),46);
    self.status.frame = CGRectMake(x+8,y+50,w-16,40);
    self.table.frame = CGRectMake(x,y+94,w,MAX(0,CGRectGetHeight(safe)-94));
}
- (BOOL)busy { return self.pending || self.closingRow || self.queue.count; }
- (void)updateButtons {
    self.closeAllButton.enabled = !self.busy && self.rows.count;
    self.closeAllButton.alpha = self.closeAllButton.enabled ? 1 : 0.45;
}

#pragma mark Mở / đóng bảng
- (void)openPanel {
    [overlay refreshGeometry];
    [self.view layoutIfNeeded];
    overlay.expanded = YES;
    self.panel.hidden = NO;
    if (!self.busy) [self reloadApps];
}
// Xong: ẩn bảng và kết thúc app CleanTA (nếu đang mở trên CarPlay) để về Home.
- (void)closePanel {
    self.panel.hidden = YES;
    overlay.expanded = NO;
    if (self.busy) self.dismissStubWhenIdle = YES; else [self killStub];
}
- (void)killStub {
    self.dismissStubWhenIdle = NO;
    int pid = CTPid(CTStubBundle);
    if (pid <= 1 || requestToken < 0) return;
    uint64_t key = CTKey(CTStubBundle.UTF8String,pid);
    if (!key) return;
    self.stubKillAt = NSProcessInfo.processInfo.systemUptime;
    CTStubMuteUntil = self.stubKillAt + 4;
    notify_set_state(requestToken,key);
    notify_post(CTRequest);
}

#pragma mark Danh sách
- (void)pullRefresh:(UIRefreshControl *)r { [r endRefreshing]; if (!self.busy) [self reloadApps]; }
- (void)reloadApps {
    if (self.loading) return;
    self.loading = YES;
    if (!self.rows.count) self.status.text = @"Đang kiểm tra ứng dụng…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSMutableArray *rows = [NSMutableArray new]; NSString *error = nil;
        @try {
            NSArray *proxies = CTProxies();
            if (!proxies || ![CTService() respondsToSelector:NSSelectorFromString(@"pidForApplication:")]) {
                error = @"iOS này chưa cho CleanTA đọc danh sách ứng dụng.";
            } else for (id proxy in proxies) {
                if (!CTAllowed(proxy)) continue;
                NSString *bundle = CTGet(proxy,@"applicationIdentifier");
                if ([bundle isEqual:CTStubBundle]) continue;
                int pid = CTPid(bundle);
                if (pid <= 1 || CTExists(pid) == 0) continue;
                NSString *name = CTGet(proxy,@"localizedName");
                NSMutableDictionary *row = [@{@"bundle":bundle,@"pid":@(pid),@"name":name ?: bundle} mutableCopy];
                UIImage *icon = CTAppIcon(bundle);
                if (icon) row[@"icon"] = icon;
                [rows addObject:row];
            }
            [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
                return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
            }];
        } @catch (__unused NSException *e) { error = @"Không đọc được danh sách ứng dụng."; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            self.rows = rows;
            [self.table reloadData];
            if (!self.busy) self.status.text = error ?: (rows.count ?
                [NSString stringWithFormat:@"%lu ứng dụng đang mở. Chạm vào ứng dụng để đóng.",(unsigned long)rows.count] :
                @"Không có ứng dụng nào đang mở.");
            [self updateButtons];
        });
    });
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    cell.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:19];
    cell.detailTextLabel.textColor = UIColor.lightGrayColor;
    NSDictionary *row = self.rows[index.row];
    cell.textLabel.text = row[@"name"];
    cell.imageView.image = row[@"icon"];
    BOOL closing = [self.closingRow[@"bundle"] isEqual:row[@"bundle"]];
    BOOL queued = NO;
    for (NSDictionary *q in self.queue) if ([q[@"bundle"] isEqual:row[@"bundle"]]) { queued = YES; break; }
    cell.detailTextLabel.text = closing ? @"Đang đóng…" : (queued ? @"Chờ đóng…" : row[@"bundle"]);
    UILabel *mark = [UILabel new];
    mark.text = closing || queued ? @"…" : @"✕";
    mark.font = [UIFont boldSystemFontOfSize:22];
    mark.textColor = closing || queued ? UIColor.lightGrayColor : [UIColor colorWithRed:1 green:0.42 blue:0.42 alpha:1];
    [mark sizeToFit];
    cell.accessoryView = mark;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];
    NSDictionary *row = self.rows[index.row];
    if ([self.closingRow[@"bundle"] isEqual:row[@"bundle"]]) return;
    for (NSDictionary *q in self.queue) if ([q[@"bundle"] isEqual:row[@"bundle"]]) return;
    BOOL idle = !self.busy;
    if (idle) { self.queueTotal = 0; self.queueDone = 0; }
    [self.queue addObject:row]; self.queueTotal++;
    [self.table reloadData];
    if (idle) [self processNext];
}
- (void)closeAll {
    if (self.busy || !self.rows.count) return;
    [self.queue setArray:self.rows];
    self.queueTotal = self.queue.count; self.queueDone = 0;
    [self.table reloadData];
    [self processNext];
}

#pragma mark Hàng đợi đóng
- (void)processNext {
    [self updateButtons];
    if (!self.queue.count) {
        self.closingRow = nil;
        self.status.text = self.queueTotal ?
            [NSString stringWithFormat:@"Đã đóng %lu/%lu ứng dụng.",(unsigned long)self.queueDone,(unsigned long)self.queueTotal] :
            self.status.text;
        [self updateButtons];
        if (self.dismissStubWhenIdle) [self killStub];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,800*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            if (!self.busy) {
                NSString *summary = self.status.text;
                [self reloadApps];
                // Giữ dòng tổng kết sau khi làm mới.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                    if (!self.busy && self.queueTotal) self.status.text = summary;
                });
            }
        });
        return;
    }
    NSDictionary *row = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    self.retries = 0;
    [self sendClose:row];
}
- (void)sendClose:(NSDictionary *)row {
    self.closingRow = row;
    [self.table reloadData];
    [self updateButtons];
    uint64_t key = CTKey([row[@"bundle"] UTF8String],[row[@"pid"] intValue]);
    if (!key || requestToken < 0 || replyToken < 0) { [self finishCurrent:NO]; return; }
    NSUInteger index = self.queueTotal - self.queue.count;
    self.status.text = self.queueTotal > 1 ?
        [NSString stringWithFormat:@"Đang đóng %@ (%lu/%lu)…",row[@"name"],(unsigned long)index,(unsigned long)self.queueTotal] :
        [NSString stringWithFormat:@"Đang đóng %@…",row[@"name"]];
    self.pending = key;
    NSUInteger generation = ++self.generation;
    // Gỡ scene CarPlay và bật chặn tự mở lại TRƯỚC khi kill.
    @try { CTGuardPrepare(row[@"bundle"]); } @catch (__unused NSException *e) {}
    // Server chỉ xử lý một lệnh một lúc; chờ nếu vừa gửi lệnh đóng app CleanTA.
    NSTimeInterval wait = MAX(0.35, 3.6 - (NSProcessInfo.processInfo.systemUptime - self.stubKillAt));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(wait*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        if (self.pending != key || self.generation != generation) return;
        if (notify_set_state(requestToken,key) != NOTIFY_STATUS_OK || notify_post(CTRequest) != NOTIFY_STATUS_OK) {
            self.pending = 0; [self finishCurrent:NO];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((wait+7)*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        if (self.pending == key && self.generation == generation) { self.pending = 0; [self finishCurrent:NO]; }
    });
}
- (void)receiveResult:(uint64_t)result {
    if (!self.pending || (result & ~UINT64_C(3)) != self.pending || !(result & 3)) return;
    self.pending = 0;
    if ((result & 3) == 3) { [self finishCurrent:NO]; return; }
    uint64_t last = 0;
    if (sampleTokens[1] >= 0 && notify_get_state(sampleTokens[1],&last) != NOTIFY_STATUS_OK) last = 0;
    int evidence = CTOutcome(last,[self.closingRow[@"pid"] intValue]);
    if (evidence == CTOutcomeNewProcess && self.retries < 2) {
        // CarPlay đã kéo app dậy: gỡ scene lần nữa rồi đóng PID mới.
        NSMutableDictionary *fresh = [self.closingRow mutableCopy];
        fresh[@"pid"] = @((int32_t)(last >> 32));
        self.retries++;
        [self sendClose:fresh];
        return;
    }
    [self finishCurrent:(evidence == CTOutcomeStopped || evidence == CTOutcomeOldExited)];
}
- (void)finishCurrent:(BOOL)closed {
    NSDictionary *row = self.closingRow;
    if (row) {
        if (closed) {
            self.queueDone++;
            NSMutableArray *updated = [NSMutableArray new];
            for (NSDictionary *r in self.rows) if (![r[@"bundle"] isEqual:row[@"bundle"]]) [updated addObject:r];
            self.rows = updated;
        }
    }
    self.closingRow = nil;
    [self.table reloadData];
    [self processNext];
}
@end

static void CTShowPanel(void) {
    if (!overlay || !controller || !overlay.screen) {
        pendingShowPanel = YES;
        return;
    }
    pendingShowPanel = NO;
    [controller openPanel];
    notify_post(CTShowAck);
}

// CarBridge can request a CleanTA launch through SpringBoard without waking the
// app's iPhone scene. Observe that launch in SpringBoard and notify CarPlay directly.
static IMP CTOriginalOpenApplication;
static void CTPostCarPlayShowHint(void) {
    notify_post(CTShowNote);
    for (NSNumber *delay in @[@0.35, @0.9, @1.6, @2.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            notify_post(CTShowNote);
        });
    }
}
static void CTOpenApplication(id object, SEL selector, id bundle, id options, id completion) {
    BOOL cleanTA = [bundle isKindOfClass:NSString.class] && [bundle isEqualToString:CTStubBundle];
    ((void(*)(id,SEL,id,id,id))CTOriginalOpenApplication)(object,selector,bundle,options,completion);
    if (cleanTA) CTPostCarPlayShowHint();
}
static void CTInstallLaunchObserver(void) {
    Class cls = NSClassFromString(@"FBSSystemService");
    SEL selector = NSSelectorFromString(@"openApplication:options:withResult:");
    Method method = class_getInstanceMethod(cls,selector);
    BOOL compatible = method && method_getNumberOfArguments(method) == 5;
    char type[64] = {0};
    if (compatible) {
        method_getReturnType(method,type,sizeof(type));
        compatible = type[0] == 'v';
        for (unsigned i = 2; i < 5 && compatible; ++i) {
            method_getArgumentType(method,i,type,sizeof(type));
            compatible = type[0] == '@';
        }
    }
    if (compatible) {
        MSHookMessageEx(cls,selector,(IMP)CTOpenApplication,&CTOriginalOpenApplication);
    } else {
        NSLog(@"[CleanTA] SpringBoard launch observer unavailable or ABI mismatch");
    }
}
// Icon CleanTA trên CarPlay được mở (qua hook scene hoặc thông báo từ app).
static void CTStubActivated(NSString *source) {
    (void)source;
    static NSTimeInterval last;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - last < 1.5 || now < CTStubMuteUntil) return;
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{ CTShowPanel(); });
}

static void CTAttach(UIWindow *host) {
    if (!host || [host isKindOfClass:CTWindow.class] || host.hidden || host.windowLevel != UIWindowLevelNormal || !host.rootViewController) return;
    UIScreen *screen = host.screen;
    if (!screen || CGRectIsEmpty(screen.coordinateSpace.bounds)) return;
    if (overlay) {
        if (overlay.screen != screen && overlay.screen == UIScreen.mainScreen && screen != UIScreen.mainScreen) {
            overlay.hidden = YES; overlay.screen = screen;
            [overlay refreshGeometry]; overlay.hidden = NO;
        }
        if (pendingShowPanel && overlay && controller) CTShowPanel();
        return;
    }
    controller = [CTController new];
    // Gắn thẳng vào UIScreen CarPlay (scene đầu tiên có thể chỉ là dock).
    overlay = [[CTWindow alloc] initWithFrame:screen.coordinateSpace.bounds];
    overlay.screen = screen;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    overlay.windowLevel = UIWindowLevelAlert + 100;
    overlay.rootViewController = controller;
    [controller loadViewIfNeeded];
    [overlay refreshGeometry];
    overlay.hidden = NO;
    if (pendingShowPanel) CTShowPanel();
}

__attribute__((constructor)) static void CTInit(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        BOOL springboard = [bundle isEqual:@"com.apple.springboard"], carplay = [bundle isEqual:@"com.apple.CarPlayApp"];
        if (!springboard && !carplay) return;
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY);
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",RTLD_LAZY);
        for (int i = 0; i < 2; ++i) {
            NSString *name = [NSString stringWithFormat:@"com.sushibta.cleanta.sample.v2.%d",i];
            if (notify_register_check(name.UTF8String,&sampleTokens[i]) != NOTIFY_STATUS_OK) sampleTokens[i] = -1;
        }
        if (springboard) {
            if (notify_register_check(CTReply,&replyToken) != NOTIFY_STATUS_OK) replyToken = -1;
            if (notify_register_dispatch(CTRequest,&requestToken,dispatch_get_main_queue(),^(int token) { CTHandleRequest(); }) != NOTIFY_STATUS_OK) requestToken = -1;
            CTInstallLaunchObserver();
            return;
        }
        if (notify_register_check(CTRequest,&requestToken) != NOTIFY_STATUS_OK) requestToken = -1;
        if (notify_register_dispatch(CTReply,&replyToken,dispatch_get_main_queue(),^(int token) {
            uint64_t result = 0;
            if (notify_get_state(token,&result) == NOTIFY_STATUS_OK) [controller receiveResult:result];
        }) != NOTIFY_STATUS_OK) replyToken = -1;
        if (notify_register_dispatch(CTShowNote,&showToken,dispatch_get_main_queue(),^(int token) { CTStubActivated(@"notify"); }) != NOTIFY_STATUS_OK) showToken = -1;
        dispatch_async(dispatch_get_main_queue(), ^{
            CTGuardInit();
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
