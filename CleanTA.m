// CleanTA 0.1 — đóng app đang chạy từ màn hình CarPlay.
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
- (CGRect)fullBounds {
    // Scene-based CarPlayApp: size from the dashboard scene, not the screen.
    return self.windowScene ? self.windowScene.coordinateSpace.bounds : self.screen.coordinateSpace.bounds;
}
- (void)refreshGeometry {
    CGRect full = [self fullBounds];
    if (CGRectIsEmpty(full) || CGRectIsInfinite(full)) return;
    if (!CGRectEqualToRect(self.frame,full)) self.frame = full;
    [self.rootViewController.view setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect full = [self fullBounds];
    if (!CGRectIsEmpty(full) && !CGRectIsInfinite(full) && !CGRectEqualToRect(self.frame,full)) self.frame = full;
}
// Khi bảng đóng, mọi thao tác chạm xuyên qua CarPlay.
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    if (!self.expanded) return nil;
    return [super hitTest:p withEvent:event];
}
@end

@interface CTController : UIViewController <UICollectionViewDataSource,UICollectionViewDelegate>
@property(nonatomic,strong) UIVisualEffectView *panel;
@property(nonatomic,strong) UILabel *titleLabel, *countLabel, *status;
@property(nonatomic,strong) UIButton *closeButton, *closeAllButton;
@property(nonatomic,strong) UICollectionView *collection;
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

// 1.0.4: "Xong" left CarPlay on the blank launcher when the stub close was
// refused (SpringBoard busy sampling the previous close for ~3 s): CarPlay
// looked frozen. Leave the stub the way the Dock Home button does first.
static void CTFindDashboard(UIViewController *vc, id *out) {
    if (!vc || *out) return;
    @try {
        if ([vc respondsToSelector:NSSelectorFromString(@"environment")]) {
            id env = [vc valueForKey:@"environment"];
            if ([NSStringFromClass([env class]) isEqual:@"DBDashboard"]) { *out = env; return; }
        }
    } @catch (__unused NSException *e) {}
    for (UIViewController *child in vc.childViewControllers) CTFindDashboard(child,out);
    CTFindDashboard(vc.presentedViewController,out);
}
static BOOL CTGoHome(void) {
    id dash = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || ![scene.session.persistentIdentifier containsString:@"DBDashboard"]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) CTFindDashboard(w.rootViewController,&dash);
    }
    SEL tapped = NSSelectorFromString(@"_homeTapped:");
    if (dash && [dash respondsToSelector:tapped]) {
        @try { ((void(*)(id,SEL,id))objc_msgSend)(dash,tapped,nil); return YES; }
        @catch (NSException *e) { }
    }
    return NO;
}

// Nhóm ứng dụng: chỉ để tô màu chip, không phải trạng thái phát/định vị trực tiếp.
static NSString *CTKind(NSString *bundle) {
    static NSSet *nav, *media; static dispatch_once_t once;
    dispatch_once(&once, ^{
        nav = [NSSet setWithArray:@[@"com.apple.Maps",@"com.google.Maps",@"vn.vietmap.live",@"com.banyac.midrive.intl"]];
        media = [NSSet setWithArray:@[@"com.google.ios.youtube",@"com.google.ios.youtubemusic",@"com.netflix.Netflix",@"com.apple.Music",@"com.apple.podcasts",@"com.apple.tv",@"com.spotify.client",@"com.soundcloud.TouchApp"]];
    });
    if ([nav containsObject:bundle]) return @"nav";
    if ([media containsObject:bundle]) return @"media";
    return @"run";
}
@interface CTAppCell : UICollectionViewCell
@property(nonatomic,strong) UIImageView *icon;
@property(nonatomic,strong) UILabel *name, *chip, *closeMark;
- (void)configure:(NSDictionary *)row closing:(BOOL)closing queued:(BOOL)queued;
@end
@implementation CTAppCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIView *c = self.contentView;
        c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.055];
        c.layer.cornerRadius = 15; c.layer.cornerCurve = kCACornerCurveContinuous;
        c.layer.borderWidth = 1; c.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.09].CGColor;
        c.clipsToBounds = YES;
        _icon = [UIImageView new];
        _icon.layer.cornerRadius = 9; _icon.layer.cornerCurve = kCACornerCurveContinuous; _icon.clipsToBounds = YES;
        _name = [UILabel new];
        _name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _name.textColor = UIColor.whiteColor; _name.adjustsFontSizeToFitWidth = YES; _name.minimumScaleFactor = 0.8;
        _chip = [UILabel new];
        _chip.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
        _chip.textAlignment = NSTextAlignmentCenter;
        _chip.layer.cornerRadius = 8; _chip.clipsToBounds = YES;
        _closeMark = [UILabel new];
        _closeMark.text = @"\u2715";
        _closeMark.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        _closeMark.textColor = [UIColor colorWithWhite:1 alpha:0.42];
        _closeMark.textAlignment = NSTextAlignmentCenter;
        for (UIView *v in @[_icon,_name,_chip,_closeMark]) [c addSubview:v];
    }
    return self;
}
- (void)configure:(NSDictionary *)row closing:(BOOL)closing queued:(BOOL)queued {
    self.icon.image = row[@"icon"];
    self.name.text = row[@"name"];
    UIColor *accent; NSString *label;
    if (closing)      { accent = [UIColor colorWithWhite:1 alpha:0.55]; label = @"\u0110ang \u0111\u00f3ng\u2026"; }
    else if (queued)  { accent = [UIColor colorWithWhite:1 alpha:0.55]; label = @"Ch\u1edd \u0111\u00f3ng\u2026"; }
    else {
        NSString *kind = CTKind(row[@"bundle"]);
        if ([kind isEqual:@"nav"])        { accent = [UIColor colorWithRed:0.22 green:0.78 blue:0.85 alpha:1]; label = @"B\u1ea3n \u0111\u1ed3"; }
        else if ([kind isEqual:@"media"]) { accent = [UIColor colorWithRed:1 green:0.71 blue:0.24 alpha:1];  label = @"Gi\u1ea3i tr\u00ed"; }
        else                              { accent = [UIColor colorWithWhite:0.68 alpha:1];                  label = @"\u0110ang ch\u1ea1y"; }
    }
    self.chip.text = label; self.chip.textColor = accent;
    self.chip.backgroundColor = [accent colorWithAlphaComponent:0.16];
    self.closeMark.hidden = closing || queued;
    self.contentView.alpha = (closing || queued) ? 0.5 : 1;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width, h = self.contentView.bounds.size.height, pad = 12;
    CGFloat ic = MIN(40, h*0.36);
    self.icon.frame = CGRectMake(pad, pad, ic, ic);
    self.closeMark.frame = CGRectMake(w-27, 6, 21, 21);
    self.name.frame = CGRectMake(pad, pad+ic+7, w-2*pad, 20);
    CGFloat cw = MIN(w-2*pad, [self.chip sizeThatFits:CGSizeMake(999,22)].width + 18);
    self.chip.frame = CGRectMake(pad, h-pad-22, MAX(44,cw), 22);
}
@end
@implementation CTController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.rows = @[]; self.queue = [NSMutableArray new];
    UIColor *cyan = [UIColor colorWithRed:0.22 green:0.78 blue:0.85 alpha:1];
    UIColor *danger = [UIColor colorWithRed:1 green:0.36 blue:0.33 alpha:1];

    self.panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    self.panel.hidden = YES;
    [self.view addSubview:self.panel];
    UIView *content = self.panel.contentView;

    self.titleLabel = [UILabel new];
    self.titleLabel.text = @"\u1ee8ng d\u1ee5ng \u0111ang ch\u1ea1y";
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy];

    self.countLabel = [UILabel new];
    self.countLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    self.countLabel.textColor = cyan;
    self.countLabel.backgroundColor = [cyan colorWithAlphaComponent:0.16];
    self.countLabel.textAlignment = NSTextAlignmentCenter;
    self.countLabel.layer.cornerRadius = 11; self.countLabel.clipsToBounds = YES;

    self.status = [UILabel new];
    self.status.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    self.status.textColor = [UIColor colorWithWhite:0.62 alpha:1];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"\u2715" forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.closeButton.tintColor = [UIColor colorWithWhite:0.72 alpha:1];
    self.closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    self.closeButton.layer.cornerRadius = 20;
    [self.closeButton addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 11; layout.minimumLineSpacing = 11;
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.backgroundColor = UIColor.clearColor;
    self.collection.showsVerticalScrollIndicator = NO;
    self.collection.delegate = self; self.collection.dataSource = self;
    [self.collection registerClass:CTAppCell.class forCellWithReuseIdentifier:@"app"];

    self.closeAllButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeAllButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    [self.closeAllButton setTitleColor:danger forState:UIControlStateNormal];
    self.closeAllButton.backgroundColor = [danger colorWithAlphaComponent:0.14];
    self.closeAllButton.layer.cornerRadius = 13; self.closeAllButton.layer.borderWidth = 1;
    self.closeAllButton.layer.borderColor = [danger colorWithAlphaComponent:0.28].CGColor;
    [self.closeAllButton addTarget:self action:@selector(closeAll) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[self.titleLabel,self.countLabel,self.status,self.closeButton,self.collection,self.closeAllButton]) [content addSubview:v];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.panel.frame = self.view.bounds;
    CGRect b = self.view.bounds;
    CGFloat pad = 18, x = pad, w = MAX(1,CGRectGetWidth(b)-2*pad), y = pad, headH = 40;
    self.closeButton.frame = CGRectMake(x+w-headH, y, headH, headH);
    self.countLabel.text = [NSString stringWithFormat:@"%lu",(unsigned long)self.rows.count];
    CGFloat cw = MAX(26, [self.countLabel sizeThatFits:CGSizeMake(999,22)].width + 16);
    [self.titleLabel sizeToFit];
    CGFloat tW = MIN(self.titleLabel.bounds.size.width, w-headH-cw-24);
    self.titleLabel.frame = CGRectMake(x, y, MAX(1,tW), 26);
    self.countLabel.frame = CGRectMake(x+tW+8, y+2, cw, 22);
    self.status.frame = CGRectMake(x, y+29, w-headH-12, 16);
    CGFloat footH = 48, footY = CGRectGetHeight(b)-pad-footH;
    self.closeAllButton.frame = CGRectMake(x, footY, w, footH);
    CGFloat top = y+53;
    self.collection.frame = CGRectMake(x, top, w, MAX(1, footY-12-top));
    NSInteger cols = w > 560 ? 4 : (w > 380 ? 3 : 2);
    CGFloat iw = floor((w - (cols-1)*11)/cols);
    CGFloat areaH = self.collection.bounds.size.height;
    NSInteger n = MAX(1,(NSInteger)self.rows.count);
    NSInteger rowsNeeded = (n + cols - 1)/cols;
    CGFloat ih = rowsNeeded <= 1 ? MIN(132, areaH) : MAX(84, MIN(132, floor((areaH-11)/2)));
    UICollectionViewFlowLayout *fl = (UICollectionViewFlowLayout *)self.collection.collectionViewLayout;
    fl.itemSize = CGSizeMake(MAX(60,iw), MAX(60,ih));
}
- (BOOL)busy { return self.pending || self.closingRow || self.queue.count; }
- (void)updateButtons {
    BOOL on = !self.busy && self.rows.count;
    self.closeAllButton.enabled = on;
    self.closeAllButton.alpha = on ? 1 : 0.4;
    self.closeAllButton.hidden = self.rows.count == 0;
    [self.closeAllButton setTitle:[NSString stringWithFormat:@"\u0110\u00f3ng t\u1ea5t c\u1ea3 %lu \u1ee9ng d\u1ee5ng",(unsigned long)self.rows.count] forState:UIControlStateNormal];
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
    CTGoHome();
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
    // SpringBoard refuses while it is still sampling a previous close; check
    // and retry (up to 3 times, 1.5 s apart) until the launcher is gone.
    static NSUInteger attempts;
    NSUInteger attempt = ++attempts;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        int still = CTPid(CTStubBundle);
        if (still <= 1) { attempts = 0; return; }
        if (attempt >= 3) { attempts = 0; return; }
        [self killStub];
    });
}

#pragma mark Danh sách
- (void)reloadApps {
    if (self.loading) return;
    self.loading = YES;
    if (!self.rows.count) self.status.text = @"\u0110ang ki\u1ec3m tra \u1ee9ng d\u1ee5ng\u2026";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSMutableArray *rows = [NSMutableArray new]; NSString *error = nil;
        @try {
            NSArray *proxies = CTProxies();
            if (!proxies || ![CTService() respondsToSelector:NSSelectorFromString(@"pidForApplication:")]) {
                error = @"iOS n\u00e0y ch\u01b0a cho CleanTA \u0111\u1ecdc danh s\u00e1ch \u1ee9ng d\u1ee5ng.";
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
        } @catch (__unused NSException *e) { error = @"Kh\u00f4ng \u0111\u1ecdc \u0111\u01b0\u1ee3c danh s\u00e1ch \u1ee9ng d\u1ee5ng."; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            self.rows = rows;
            [self.collection reloadData];
            if (!self.busy) self.status.text = error ?: (rows.count ?
                @"Ch\u1ea1m v\u00e0o \u1ee9ng d\u1ee5ng \u0111\u1ec3 \u0111\u00f3ng" :
                @"Kh\u00f4ng c\u00f3 \u1ee9ng d\u1ee5ng n\u00e0o \u0111ang m\u1edf.");
            [self updateButtons];
            [self.view setNeedsLayout];
        });
    });
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return self.rows.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    CTAppCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"app" forIndexPath:ip];
    NSDictionary *row = self.rows[ip.item];
    BOOL closing = [self.closingRow[@"bundle"] isEqual:row[@"bundle"]], queued = NO;
    for (NSDictionary *q in self.queue) if ([q[@"bundle"] isEqual:row[@"bundle"]]) { queued = YES; break; }
    [cell configure:row closing:closing queued:queued];
    return cell;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = self.rows[ip.item];
    if ([self.closingRow[@"bundle"] isEqual:row[@"bundle"]]) return;
    for (NSDictionary *q in self.queue) if ([q[@"bundle"] isEqual:row[@"bundle"]]) return;
    BOOL idle = !self.busy;
    if (idle) { self.queueTotal = 0; self.queueDone = 0; }
    [self.queue addObject:row]; self.queueTotal++;
    [self.collection reloadData];
    if (idle) [self processNext];
}
- (void)closeAll {
    if (self.busy || !self.rows.count) return;
    [self.queue setArray:self.rows];
    self.queueTotal = self.queue.count; self.queueDone = 0;
    [self.collection reloadData];
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
    [self.collection reloadData];
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
    [self.collection reloadData];
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
    if (now - last < 1.5 || now < CTStubMuteUntil) { return; }
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{ CTShowPanel(); });
}

// 1.0.5: level Alert+300. MultiTA's Dock swipe zone (Alert+200, top-left
// 60x70) sat above the panel and swallowed taps on "Xong". The window passes
// every touch through while the panel is closed (see -hitTest:).
// 1.0.3: a window given only a screen is never shown in scene-based
// CarPlayApp (iOS 15/16), so the panel could stay invisible while the blank
// CleanTA stub covered CarPlay ("frozen"). Attach to the dashboard scene.
static BOOL CTIsDashboard(UIWindowScene *scene) {
    return [scene.session.persistentIdentifier containsString:@"DBDashboard"];
}
static void CTAttach(UIWindow *host) {
    if (!host || [host isKindOfClass:CTWindow.class] || host.hidden || host.windowLevel != UIWindowLevelNormal || !host.rootViewController) return;
    UIScreen *screen = host.screen;
    if (!screen || CGRectIsEmpty(screen.coordinateSpace.bounds)) return;
    UIWindowScene *scene = host.windowScene;
    if (overlay && scene && CTIsDashboard(scene) && overlay.windowScene != scene) {
        overlay.windowScene = scene; overlay.windowLevel = UIWindowLevelAlert + 300;
        [overlay refreshGeometry]; overlay.hidden = NO;
    }
    if (overlay) {
        if (overlay.screen != screen && overlay.screen == UIScreen.mainScreen && screen != UIScreen.mainScreen) {
            overlay.hidden = YES; overlay.screen = screen;
            [overlay refreshGeometry]; overlay.hidden = NO;
        }
        if (pendingShowPanel && overlay && controller) CTShowPanel();
        return;
    }
    controller = [CTController new];
    // Prefer the CarPlay dashboard scene; fall back to the screen (pre-1.0.3).
    if (scene && CTIsDashboard(scene)) overlay = [[CTWindow alloc] initWithWindowScene:scene];
    else { overlay = [[CTWindow alloc] initWithFrame:screen.coordinateSpace.bounds]; overlay.screen = screen; }
    overlay.backgroundColor = UIColor.clearColor;
    overlay.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    overlay.windowLevel = UIWindowLevelAlert + 300;
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
