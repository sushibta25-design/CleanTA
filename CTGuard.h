// CTGuard (0.1.6) — chỉ chạy trong CarPlayApp.
// Log 0.1.5: sau khi kill, DashBoard vẫn giữ scene <bundle>:dashboard và
// <bundle>:widget, tiếp tục updateSettings rồi foreground lại -> FrontBoard
// spawn process mới (~100ms). Guard này:
//   1. Huỷ mọi FBScene của app trên màn xe TRƯỚC khi kill.
//   2. Trong cửa sổ chặn (15s): bỏ qua foreground/updateSettings của DashBoard
//      cho đúng bundle đó. createScene chỉ ghi log, không chặn (trả nil có thể crash).
// Mọi hook đều kiểm tra ABI lúc chạy; thiếu method thì bỏ qua và ghi log.

static NSMutableDictionary<NSString *, NSNumber *> *CTSuppressUntil;
static NSMutableSet<NSString *> *CTGuardHooks;
static const NSTimeInterval CTSuppressSeconds = 15;

static BOOL CTIDMatches(NSString *identifier, NSString *bundle) {
    if (![identifier isKindOfClass:NSString.class] || !bundle.length) return NO;
    // Ví dụ: Car[2-3]:vn.vietmap.live:dashboard, Car[2-3]:com.apple.CarPlayTemplateUIHost:vn.vietmap.live
    return [[identifier componentsSeparatedByString:@":"] containsObject:bundle];
}
static NSString *CTSuppressedMatch(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    @synchronized (CTSuppressUntil) {
        for (NSString *bundle in CTSuppressUntil.allKeys) {
            if (CTSuppressUntil[bundle].doubleValue < now) { [CTSuppressUntil removeObjectForKey:bundle]; CTLog(@"SUPPRESS_END bundle=%@",bundle); continue; }
            if (CTIDMatches(identifier,bundle)) return bundle;
        }
    }
    return nil;
}
static void CTSuppress(NSString *bundle) {
    @synchronized (CTSuppressUntil) { CTSuppressUntil[bundle] = @(NSProcessInfo.processInfo.systemUptime + CTSuppressSeconds); }
    CTLog(@"SUPPRESS_BEGIN bundle=%@ seconds=%.0f",bundle,CTSuppressSeconds);
}
static NSArray *CTAllScenes(void) {
    id manager = CTReadObject(NSClassFromString(@"FBSceneManager"),@"sharedInstance");
    if (!manager) return @[];
    id scenes = nil;
    for (NSString *name in @[@"scenes",@"allScenes"]) { scenes = CTReadObject(manager,name); if (scenes) break; }
    if (!scenes) { @try { scenes = [[manager valueForKey:@"_scenesByID"] allValues]; } @catch (__unused NSException *e) {} }
    if ([scenes isKindOfClass:NSSet.class]) return [scenes allObjects];
    if ([scenes isKindOfClass:NSArray.class]) return scenes;
    if ([scenes isKindOfClass:NSDictionary.class]) return [scenes allValues];
    return @[];
}
static NSUInteger CTDestroyScenes(NSString *bundle) {
    id manager = CTReadObject(NSClassFromString(@"FBSceneManager"),@"sharedInstance");
    SEL destroy = NSSelectorFromString(@"destroyScene:withTransitionContext:");
    NSMutableArray *ids = [NSMutableArray new];
    for (id scene in CTAllScenes()) {
        NSString *identifier = CTReadObject(scene,@"identifier");
        if (CTIDMatches(identifier,bundle)) [ids addObject:identifier];
    }
    CTLog(@"SCENES_MATCH bundle=%@ count=%lu ids=%@ total=%lu",bundle,(unsigned long)ids.count,ids,(unsigned long)CTAllScenes().count);
    if (![manager respondsToSelector:destroy]) { CTLog(@"DESTROY unavailable"); return 0; }
    NSUInteger done = 0;
    for (NSString *identifier in ids) {
        @try {
            ((void(*)(id,SEL,id,id))objc_msgSend)(manager,destroy,identifier,nil);
            done++; CTLog(@"DESTROY scene=%@",identifier);
        } @catch (NSException *e) { CTLog(@"DESTROY exception=%@ scene=%@",e.name,identifier); }
    }
    return done;
}
static BOOL CTHookCompatible(Class cls, SEL sel, unsigned objectArgs, char ret) {
    Method m = class_getInstanceMethod(cls,sel);
    if (!m || method_getNumberOfArguments(m) != objectArgs + 2) return NO;
    char type[128] = {0}; method_getReturnType(m,type,sizeof(type)); if (type[0] != ret) return NO;
    for (unsigned i = 2; i < objectArgs + 2; i++) { method_getArgumentType(m,i,type,sizeof(type)); if (type[0] != '@') return NO; }
    return YES;
}
// completion của DashBoard/FrontBoard là block 0 hoặc 1 tham số (BOOL/obj).
// Gọi với 0/nil an toàn cho cả hai kiểu trên arm64.
static void CTFinish(id completion) { if (completion) ((void(^)(id))completion)(nil); }

static void CTInstallGuard(void) {
    if (!CTGuardHooks) CTGuardHooks = [NSMutableSet new];
    // 1. DashBoard foreground lại app vừa bị đóng.
    {
        NSString *name = @"guard DBApplicationSceneViewController foregroundSceneWithSettings:completion:";
        Class cls = NSClassFromString(@"DBApplicationSceneViewController");
        SEL sel = NSSelectorFromString(@"foregroundSceneWithSettings:completion:");
        if (![CTGuardHooks containsObject:name]) {
            if (CTHookCompatible(cls,sel,2,'v')) {
                __block IMP original = NULL;
                IMP replacement = imp_implementationWithBlock(^(id object,id settings,id completion) {
                    NSString *hit = nil;
                    @try {
                        hit = CTSuppressedMatch(CTReadObject(object,@"sceneID"));
                        if (!hit) hit = CTSuppressedMatch(CTReadObject(object,@"identifier"));
                    } @catch (__unused NSException *e) {}
                    if (hit) { CTLog(@"BLOCK foreground bundle=%@",hit); CTFinish(completion); return; }
                    ((void(*)(id,SEL,id,id))original)(object,sel,settings,completion);
                });
                MSHookMessageEx(cls,sel,replacement,&original);
                [CTGuardHooks addObject:name]; CTLog(@"GUARD installed foreground");
            } else CTLog(@"GUARD skip foreground reason=absent_or_ABI_mismatch");
        }
    }
    // 2. DashBoard cập nhật settings scene dashboard/widget -> kéo process dậy.
    {
        NSString *name = @"guard FBScene updateSettings:withTransitionContext:completion:";
        Class cls = NSClassFromString(@"FBScene");
        SEL sel = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if (![CTGuardHooks containsObject:name]) {
            if (CTHookCompatible(cls,sel,3,'v')) {
                __block IMP original = NULL;
                IMP replacement = imp_implementationWithBlock(^(id object,id settings,id context,id completion) {
                    NSString *hit = nil;
                    @try { hit = CTSuppressedMatch(CTReadObject(object,@"identifier")); } @catch (__unused NSException *e) {}
                    if (hit) { CTLog(@"BLOCK updateSettings bundle=%@ scene=%@",hit,CTReadObject(object,@"identifier")); CTFinish(completion); return; }
                    ((void(*)(id,SEL,id,id,id))original)(object,sel,settings,context,completion);
                });
                MSHookMessageEx(cls,sel,replacement,&original);
                [CTGuardHooks addObject:name]; CTLog(@"GUARD installed updateSettings");
            } else CTLog(@"GUARD skip updateSettings reason=absent_or_ABI_mismatch");
        }
    }
    // 3. Tạo scene mới: chỉ ghi log để biết ai tạo lại.
    {
        NSString *name = @"guard FBSceneManager createSceneWithDefinition:initialParameters:";
        Class cls = NSClassFromString(@"FBSceneManager");
        SEL sel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![CTGuardHooks containsObject:name]) {
            if (CTHookCompatible(cls,sel,2,'@')) {
                __block IMP original = NULL;
                IMP replacement = imp_implementationWithBlock(^id(id object,id definition,id parameters) {
                    @try {
                        NSString *identifier = CTReadObject(definition,@"identifier");
                        NSString *hit = CTSuppressedMatch(identifier);
                        if (hit) CTLog(@"CREATE_DURING_SUPPRESS bundle=%@ scene=%@ stack=%@",hit,identifier,NSThread.callStackSymbols);
                    } @catch (__unused NSException *e) {}
                    return ((id(*)(id,SEL,id,id))original)(object,sel,definition,parameters);
                });
                MSHookMessageEx(cls,sel,replacement,&original);
                [CTGuardHooks addObject:name]; CTLog(@"GUARD installed create(log-only)");
            } else CTLog(@"GUARD skip create reason=absent_or_ABI_mismatch");
        }
    }
}
// Gọi ngay trước khi gửi lệnh kill.
static void CTGuardPrepare(NSString *bundle) {
    CTInstallGuard();
    CTSuppress(bundle);
    CTDestroyScenes(bundle);
}
static void CTGuardInit(void) {
    CTSuppressUntil = [NSMutableDictionary new];
    CTInstallGuard();
}
