#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import "CTProtocol.h"
#import "CTDiagnostics.h"
#import "CTGuard.h"

static const char *CTRequest = "com.sushibta.cleanta.close.v1";
static const char *CTReply = "com.sushibta.cleanta.result.v1";
static int requestToken = -1, replyToken = -1;
static BOOL serverBusy;
static int sampleTokens[2] = {-1,-1};
// kill(pid, 0) probes existence only; it never sends a termination signal.
static unsigned CTExists(int pid) {
    if (pid <= 1) return 2;
    if (kill(pid,0) == 0) return 1;
    return errno == ESRCH ? 0 : (errno == EPERM ? 1 : 2);
}
static NSString *CTSampleText(uint64_t value) {
    if (!(value & 16)) return @"không đọc được";
    int pid = (int32_t)(value >> 32);
    unsigned current = (value >> 2) & 3;
    if (pid == 0) return (value & 3) == 0 ? @"không thấy tiến trình" : @"API=0, PID cũ còn/chưa rõ";
    if (pid < 0) return (value & 3) == 0 ? @"PID cũ đã mất; API không trả PID hiện tại" : @"API chưa trả được PID";
    return [NSString stringWithFormat:@"PID %d (%@)",pid,current == 0 ? @"đã mất" : current == 1 ? @"còn" : @"chưa rõ"];
}
static id CTGet(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    return [object respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(object,sel) : nil;
}
static id CTService(void) { return CTGet(NSClassFromString(@"FBSSystemService"), @"sharedService"); }
static BOOL CTInSpringBoard(void) {
    static BOOL value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]; });
    return value;
}
// SpringBoard: đọc PID trong tiến trình (SBApplicationController) hoặc hỏi
// runningboardd. KHÔNG gọi client FBSSystemService từ SpringBoard: đó là XPC
// gửi ngược vào chính server của nó trên main queue -> timeout, trả -1.
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
// Kết thúc qua RunningBoard (iOS 14+). SpringBoard có entitlement
// com.apple.runningboard.terminateprocess. Trả YES nếu request chạy không lỗi.
static BOOL CTTerminate(NSString *bundle, NSString **why) {
    Class ctxCls = NSClassFromString(@"RBSTerminateContext"), reqCls = NSClassFromString(@"RBSTerminateRequest");
    Class predCls = NSClassFromString(@"RBSProcessPredicate");
    SEL ctxSel = NSSelectorFromString(@"defaultContextWithExplanation:");
    SEL predSel = NSSelectorFromString(@"predicateMatchingBundleIdentifier:");
    SEL initSel = NSSelectorFromString(@"initWithPredicate:context:");
    SEL execSel = NSSelectorFromString(@"execute:");
    if (![ctxCls respondsToSelector:ctxSel] || ![predCls respondsToSelector:predSel] || ![reqCls instancesRespondToSelector:initSel]) {
        if (why) *why = @"RBS classes missing"; return NO;
    }
    id ctx = ((id(*)(id,SEL,id))objc_msgSend)(ctxCls,ctxSel,@"CleanTA: user requested close");
    @try {
        [ctx setValue:@0 forKey:@"reportType"];
        [ctx setValue:@(0xbaadca11ULL) forKey:@"exceptionCode"];
        [ctx setValue:@40 forKey:@"maximumTerminationResistance"]; // mức UserInteractive: vượt qua audio/nav đang chạy
    } @catch (NSException *e) { CTLog(@"RBS context KVC exception=%@",e.name); }
    id pred = ((id(*)(id,SEL,id))objc_msgSend)(predCls,predSel,bundle);
    id req = ((id(*)(id,SEL,id,id))objc_msgSend)([reqCls alloc],initSel,pred,ctx);
    if (![req respondsToSelector:execSel]) { if (why) *why = @"execute: missing"; return NO; }
    NSError *err = nil;
    BOOL ok = ((BOOL(*)(id,SEL,NSError **))objc_msgSend)(req,execSel,&err);
    if (why) *why = err ? err.description : (ok ? @"ok" : @"NO without error");
    return ok;
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
    CTLog(@"REQUEST key=%llu",(unsigned long long)key);
    if (serverBusy) { CTLog(@"REJECT busy"); CTRespond(key,3); return; }
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
        if (!target) { CTLog(@"REJECT stale PID, disallowed target or missing proxy"); CTRespond(key,3); return; }
        CTWatch(target);
        CTLog(@"TERMINATE key=%llu bundle=%@ via=RBS before=%@",(unsigned long long)key,target,CTProcess(CTPid(target)));
        serverBusy = YES;
        NSString *why = nil;
        BOOL ok = CTTerminate(target,&why);
        CTLog(@"TERMINATE returned bundle=%@ ok=%d detail=%@",target,ok,why);
        if (!ok) {
            // Dự phòng: đường cũ qua FBSSystemService.
            id service = CTService();
            SEL terminate = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
            if ([service respondsToSelector:terminate]) {
                ((void(*)(id,SEL,id,long long,BOOL,id))objc_msgSend)(service,terminate,target,1,NO,@"CleanTA: user requested close");
                CTLog(@"TERMINATE fallback FBSSystemService sent");
            }
        }
        int original = (uint32_t)(key >> 2);
        for (int i = 0; i < 2; ++i) {
            if (sampleTokens[i] >= 0) notify_set_state(sampleTokens[i],0);
            int slot = i;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(i == 0 ? 1 : 3)*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                uint64_t sample = 0; unsigned result = 2;
                @try {
                    int pid = CTPid(target);
                    unsigned oldState = CTExists(original);
                    unsigned currentState = pid > 1 ? CTExists(pid) : 2;
                    CTLog(@"SAMPLE key=%llu second=%d bundle=%@ old=%@ current=%@",(unsigned long long)key,slot == 0 ? 1 : 3,target,CTProcess(original),CTProcess(pid));
                    sample = CTMakeSample(pid,oldState,currentState);
                    if (CTSampleStopped(sample)) result = 1;
                } @catch (NSException *e) { CTLog(@"SAMPLE exception=%@",e.name); result = 3; }
                if (sampleTokens[slot] >= 0) notify_set_state(sampleTokens[slot],sample);
                if (slot == 1) { CTRespond(key,result); serverBusy = NO; }
            });
        }
    } @catch (NSException *e) { serverBusy = NO; CTLog(@"REQUEST exception=%@",e.name); CTRespond(key,3); }
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
@property(nonatomic,copy) NSDictionary *closingRow;
@property(nonatomic,assign) NSUInteger retries;
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
    UIButton *trace = [self button:@"Log 60s" action:@selector(startTrace)]; trace.tag = 4; [self.panel addSubview:trace];
    UILabel *title = [UILabel new]; title.text = @"CleanTA 0.1.6"; title.textAlignment = NSTextAlignmentCenter;
    title.textColor = UIColor.whiteColor; title.font = [UIFont boldSystemFontOfSize:20]; title.tag = 3; [self.panel addSubview:title];
    self.status = [UILabel new]; self.status.font = [UIFont systemFontOfSize:14];
    self.status.textColor = UIColor.lightGrayColor; self.status.numberOfLines = 3; self.status.textAlignment = NSTextAlignmentCenter;
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
    [self.panel viewWithTag:3].frame = CGRectMake(x+76,y,MAX(0,w-266),44);
    [self.panel viewWithTag:4].frame = CGRectMake(x+w-190,y,90,44);
    self.status.frame = CGRectMake(x+8,y+44,w-16,62);
    self.table.frame = CGRectMake(x,y+106,w,MAX(0,CGRectGetHeight(safe)-106));
}
- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.view];
    self.entry.center = CGPointMake(self.entry.center.x+d.x,self.entry.center.y+d.y);
    [g setTranslation:CGPointZero inView:self.view]; [self.view setNeedsLayout];
}
- (void)openPanel { [overlay refreshGeometry]; [self.view layoutIfNeeded]; overlay.expanded = YES; self.panel.hidden = NO; [self reloadApps]; }
- (void)closePanel { self.panel.hidden = YES; overlay.expanded = NO; }
- (void)startTrace {
    CTStartTrace();
    notify_post("com.sushibta.cleanta.trace.v1");
    self.status.text = @"Đang ghi log 60 giây. Thử đóng app một lần. Log: Library/Logs/CleanTA.";
}
- (void)reloadApps {
    if (self.pending || self.loading) return;
    CTLog(@"REFRESH begin");
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
                unsigned existence = CTExists(pid);
                CTLog(@"ROW bundle=%@ process=%@",bundle,CTProcess(pid));
                if (existence == 0) continue;
                NSString *name = CTGet(proxy,@"localizedName");
                [rows addObject:@{@"bundle":bundle,@"pid":@(pid),@"name":name ?: bundle}];
            }
            [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
                return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
            }];
        } @catch(NSException *e) { error = @"Không đọc được ứng dụng. Cần kiểm tra tương thích iOS."; }
        dispatch_async(dispatch_get_main_queue(), ^{
            CTLog(@"REFRESH complete count=%lu error=%@",(unsigned long)rows.count,error ?: @"none");
            self.loading = NO; self.rows = rows; [self.table reloadData];
            self.status.text = error ?: (rows.count ? @"Đã làm mới. Chọn app để gửi lệnh đóng; Log 60s để ghi chẩn đoán." : @"Chưa tìm thấy ứng dụng đang chạy có thể đóng. Thử mở VML rồi làm mới.");
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
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • PID %@",row[@"bundle"],row[@"pid"]]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES]; if (self.pending || self.loading) return;
    NSDictionary *row = self.rows[index.row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[@"Đóng " stringByAppendingString:row[@"name"]]
        message:@"Gửi yêu cầu đóng và kiểm tra tiến trình. App có thể được mở lại; kết quả sẽ hiện sau 3 giây." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng ứng dụng" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self closeApp:row]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)closeApp:(NSDictionary *)row { self.retries = 0; [self sendClose:row]; }
- (void)sendClose:(NSDictionary *)row {
    if (requestToken < 0 || replyToken < 0) { self.status.text = @"Không kết nối được CleanTA. Thử respring."; return; }
    uint64_t key = CTKey([row[@"bundle"] UTF8String],[row[@"pid"] intValue]);
    if (!key) { self.status.text = @"PID không hợp lệ. Bấm Làm mới."; return; }
    CTWatch(row[@"bundle"]);
    CTLog(@"UI_CLOSE key=%llu bundle=%@ listedPID=%@ retry=%lu",(unsigned long long)key,row[@"bundle"],row[@"pid"],(unsigned long)self.retries);
    self.closingRow = row; self.pending = key; NSUInteger generation = ++self.generation;
    self.status.text = self.retries ?
        [NSString stringWithFormat:@"%@: bị mở lại, thử lại %lu/2 (PID %@)…",row[@"name"],(unsigned long)self.retries,row[@"pid"]] :
        [NSString stringWithFormat:@"%@: PID %@ — gỡ scene CarPlay rồi đóng…",row[@"name"],row[@"pid"]];
    // Gỡ scene dashboard/widget/app trên màn xe và bật chặn relaunch TRƯỚC khi kill.
    @try { CTGuardPrepare(row[@"bundle"]); } @catch (NSException *e) { CTLog(@"GUARD exception=%@",e.name); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        if (self.pending != key || self.generation != generation) return;
        if (notify_set_state(requestToken,key) != NOTIFY_STATUS_OK || notify_post(CTRequest) != NOTIFY_STATUS_OK) {
            self.pending = 0; self.status.text = @"Không gửi được yêu cầu đóng.";
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,7*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        if (self.pending == key && self.generation == generation) {
            self.pending = 0; self.status.text = @"Chưa nhận được phản hồi. Bấm Làm mới để kiểm tra.";
        }
    });
}
- (void)receiveResult:(uint64_t)result {
    if (!self.pending || (result & ~UINT64_C(3)) != self.pending || !(result & 3)) return;
    CTLog(@"UI_RESULT raw=%llu",(unsigned long long)result);
    uint64_t key = self.pending; self.pending = 0;
    if ((result & 3) == 3) {
        self.status.text = [NSString stringWithFormat:@"%@: chưa thực hiện/kiểm tra được lệnh đóng. Bấm Làm mới.",self.closingRow[@"name"]];
        return;
    }
    uint64_t first = 0, last = 0;
    if (sampleTokens[0] >= 0 && notify_get_state(sampleTokens[0],&first) != NOTIFY_STATUS_OK) first = 0;
    if (sampleTokens[1] >= 0 && notify_get_state(sampleTokens[1],&last) != NOTIFY_STATUS_OK) last = 0;
    int original = [self.closingRow[@"pid"] intValue];
    int evidence = CTOutcome(last,original);
    if (evidence == CTOutcomeNewProcess && self.retries < 2) {
        // DashBoard đã kéo app dậy: cập nhật PID mới, gỡ scene lần nữa, gửi lại.
        NSMutableDictionary *fresh = [self.closingRow mutableCopy]; fresh[@"pid"] = @((int32_t)(last >> 32));
        NSMutableArray *updated = [NSMutableArray new];
        for (NSDictionary *row in self.rows) [updated addObject:[row[@"bundle"] isEqual:fresh[@"bundle"]] ? fresh : row];
        self.rows = updated; [self.table reloadData];
        self.retries++;
        CTLog(@"RETRY bundle=%@ newPID=%@ attempt=%lu",fresh[@"bundle"],fresh[@"pid"],(unsigned long)self.retries);
        [self sendClose:fresh];
        return;
    }
    NSString *outcome = evidence == CTOutcomeStopped ? @"Đã dừng tại giây 3" :
        evidence == CTOutcomeNewProcess ? @"Có tiến trình mới" :
        evidence == CTOutcomeOldExited ? @"PID cũ đã đóng; chưa rõ tiến trình mới" : @"Chưa xác nhận đã dừng";
    NSString *tries = self.retries ? [NSString stringWithFormat:@" • đã thử lại %lu",(unsigned long)self.retries] : @"";
    self.status.text = [NSString stringWithFormat:@"%@ • trước: %d • %@%@\n1s: %@ | 3s: %@",self.closingRow[@"name"],original,outcome,tries,CTSampleText(first),CTSampleText(last)];
    NSMutableArray *updated = [NSMutableArray new];
    for (NSDictionary *row in self.rows) {
        if (CTKey([row[@"bundle"] UTF8String],[row[@"pid"] intValue]) != key) { [updated addObject:row]; continue; }
        if (evidence == CTOutcomeStopped || evidence == CTOutcomeOldExited) continue;
        if (evidence == CTOutcomeNewProcess) {
            NSMutableDictionary *fresh = [row mutableCopy]; fresh[@"pid"] = @((int32_t)(last >> 32)); [updated addObject:fresh];
        } else [updated addObject:row];
    }
    self.rows = updated; [self.table reloadData];
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
        dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",RTLD_LAZY);
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        CTDiagnosticsInit();
        if ([bundle isEqual:@"com.apple.springboard"] || [bundle isEqual:@"com.apple.CarPlayApp"]) {
            for (int i = 0; i < 2; ++i) {
                NSString *name = [NSString stringWithFormat:@"com.sushibta.cleanta.sample.v2.%d",i];
                if (notify_register_check(name.UTF8String,&sampleTokens[i]) != NOTIFY_STATUS_OK) sampleTokens[i] = -1;
            }
        }
        if ([bundle isEqual:@"com.apple.springboard"]) {
            if (notify_register_check(CTReply,&replyToken) != NOTIFY_STATUS_OK) replyToken = -1;
            if (notify_register_dispatch(CTRequest,&requestToken,dispatch_get_main_queue(),^(int token) { CTHandleRequest(); }) != NOTIFY_STATUS_OK) requestToken = -1;
        } else if ([bundle isEqual:@"com.apple.CarPlayApp"]) {
            if (notify_register_check(CTRequest,&requestToken) != NOTIFY_STATUS_OK) requestToken = -1;
            if (notify_register_dispatch(CTReply,&replyToken,dispatch_get_main_queue(),^(int token) {
                uint64_t result = 0; if (notify_get_state(token,&result) == NOTIFY_STATUS_OK) [controller receiveResult:result];
            }) != NOTIFY_STATUS_OK) replyToken = -1;
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
}
