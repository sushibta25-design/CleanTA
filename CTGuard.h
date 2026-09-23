// CTGuard — chỉ chạy trong CarPlayApp.
// App dẫn đường (VML, Google Maps) bị kill thì DashBoard tạo lại + activate scene
// :widget/:dashboard gửi sang CarPlayTemplateUIHost -> app bị bootstrap lại.
// Guard: gỡ scene trước khi kill, rồi chặn foreground/updateSettings/activate của
// đúng app đó trong vài giây (CarPlay chỉ thử mở lại ngay sau khi app chết).
// Ngoài ra nhận biết khi icon app CleanTA được mở trên CarPlay để hiện bảng.

static NSString *const CTStubBundle = @"com.sushibta.cleanta.app";
static const NSTimeInterval CTSuppressSeconds = 5;
static void CTStubActivated(NSString *source); // định nghĩa trong CleanTA.m

static NSMutableDictionary<NSString *, NSNumber *> *CTSuppressUntil;
static NSMutableSet<NSString *> *CTGuardHooks;
static NSMapTable<NSString *, id> *CTSeenScenes;

static BOOL CTIDMatches(NSString *identifier, NSString *bundle) {
    if (![identifier isKindOfClass:NSString.class] || !bundle.length) return NO;
    // Car[2-3]:vn.vietmap.live:dashboard, Car[2-3]:com.apple.CarPlayTemplateUIHost:vn.vietmap.live
    return [[identifier componentsSeparatedByString:@":"] containsObject:bundle];
}
static void CTCheckStub(NSString *identifier, NSString *source) {
    if ([identifier isKindOfClass:NSString.class] && [identifier containsString:CTStubBundle]) CTStubActivated(source);
}
static NSString *CTSuppressedMatch(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !CTSuppressUntil) return nil;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    @synchronized (CTSuppressUntil) {
        for (NSString *bundle in CTSuppressUntil.allKeys) {
            if (CTSuppressUntil[bundle].doubleValue < now) { [CTSuppressUntil removeObjectForKey:bundle]; continue; }
            if (CTIDMatches(identifier,bundle)) return bundle;
        }
    }
    return nil;
}
static void CTSuppress(NSString *bundle) {
    @synchronized (CTSuppressUntil) { CTSuppressUntil[bundle] = @(NSProcessInfo.processInfo.systemUptime + CTSuppressSeconds); }
}
static void CTNoteScene(id scene) {
    NSString *identifier = CTReadObject(scene,@"identifier");
    if (![identifier isKindOfClass:NSString.class] || !CTSeenScenes) return;
    @synchronized (CTSeenScenes) { [CTSeenScenes setObject:scene forKey:identifier]; }
}
static NSUInteger CTDestroyScenes(NSString *bundle) {
    id manager = CTReadObject(NSClassFromString(@"FBSceneManager"),@"sharedInstance");
    NSMutableDictionary<NSString *, id> *targets = [NSMutableDictionary new];
    @synchronized (CTSeenScenes) {
        for (NSString *identifier in CTSeenScenes.keyEnumerator.allObjects) {
            id scene = [CTSeenScenes objectForKey:identifier];
            if (scene && CTIDMatches(identifier,bundle)) targets[identifier] = scene;
        }
    }
    SEL destroy = NSSelectorFromString(@"destroyScene:withTransitionContext:");
    SEL invalidate = NSSelectorFromString(@"invalidate");
    NSUInteger done = 0;
    for (NSString *identifier in targets) {
        @try {
            if ([manager respondsToSelector:destroy]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(manager,destroy,identifier,nil); done++;
            } else if ([targets[identifier] respondsToSelector:invalidate]) {
                ((void(*)(id,SEL))objc_msgSend)(targets[identifier],invalidate); done++;
            }
        } @catch (__unused NSException *e) {}
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
// completion là block 0 hoặc 1 tham số: gọi với nil an toàn cho cả hai trên arm64.
static void CTFinish(id completion) { if (completion) ((void(^)(id))completion)(nil); }

static NSString *CTBlockedScene(id scene) {
    NSString *identifier = nil;
    @try { identifier = CTReadObject(scene,@"identifier"); } @catch (__unused NSException *e) {}
    CTCheckStub(identifier,@"activate");
    return CTSuppressedMatch(identifier);
}
static void CTFinishBlocks(NSArray *args, NSIndexSet *blockIndexes) {
    [blockIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        id b = i < args.count ? args[i] : nil;
        if (b && b != (id)NSNull.null) ((void(^)(id))b)(nil);
    }];
}
static void CTHookActivation(void) {
    Class cls = NSClassFromString(@"FBScene"); if (!cls) return;
    unsigned count = 0; Method *list = class_copyMethodList(cls,&count);
    for (unsigned i = 0; i < count; i++) {
        SEL sel = method_getName(list[i]);
        NSString *selName = NSStringFromSelector(sel);
        if (![selName hasPrefix:@"activate"] && ![selName hasPrefix:@"_activate"]) continue;
        NSString *key = [@"activate " stringByAppendingString:selName];
        if ([CTGuardHooks containsObject:key]) continue;
        unsigned argc = method_getNumberOfArguments(list[i]) - 2;
        char type[128] = {0}; method_getReturnType(list[i],type,sizeof(type));
        BOOL ok = type[0] == 'v' && argc <= 3;
        NSMutableIndexSet *blocks = [NSMutableIndexSet new];
        for (unsigned a = 0; ok && a < argc; a++) {
            method_getArgumentType(list[i],a+2,type,sizeof(type));
            if (type[0] != '@') ok = NO; else if (type[1] == '?') [blocks addIndex:a];
        }
        if (!ok) continue;
        __block IMP original = NULL; IMP replacement = NULL;
        if (argc == 0) replacement = imp_implementationWithBlock(^(id o) {
            if (CTBlockedScene(o)) return;
            ((void(*)(id,SEL))original)(o,sel); });
        else if (argc == 1) replacement = imp_implementationWithBlock(^(id o,id a) {
            if (CTBlockedScene(o)) { CTFinishBlocks(@[a ?: NSNull.null],blocks); return; }
            ((void(*)(id,SEL,id))original)(o,sel,a); });
        else if (argc == 2) replacement = imp_implementationWithBlock(^(id o,id a,id b) {
            if (CTBlockedScene(o)) { CTFinishBlocks(@[a ?: NSNull.null,b ?: NSNull.null],blocks); return; }
            ((void(*)(id,SEL,id,id))original)(o,sel,a,b); });
        else replacement = imp_implementationWithBlock(^(id o,id a,id b,id c) {
            if (CTBlockedScene(o)) { CTFinishBlocks(@[a ?: NSNull.null,b ?: NSNull.null,c ?: NSNull.null],blocks); return; }
            ((void(*)(id,SEL,id,id,id))original)(o,sel,a,b,c); });
        MSHookMessageEx(cls,sel,replacement,&original);
        [CTGuardHooks addObject:key];
    }
    free(list);
}
static void CTInstallGuard(void) {
    if (!CTGuardHooks) CTGuardHooks = [NSMutableSet new];
    // DashBoard foreground lại app vừa bị đóng.
    {
        Class cls = NSClassFromString(@"DBApplicationSceneViewController");
        SEL sel = NSSelectorFromString(@"foregroundSceneWithSettings:completion:");
        if (![CTGuardHooks containsObject:@"foreground"] && CTHookCompatible(cls,sel,2,'v')) {
            __block IMP original = NULL;
            IMP replacement = imp_implementationWithBlock(^(id object,id settings,id completion) {
                NSString *hit = nil;
                @try {
                    NSString *sceneID = CTReadObject(object,@"sceneID"), *identifier = CTReadObject(object,@"identifier");
                    CTCheckStub(sceneID,@"foreground"); CTCheckStub(identifier,@"foreground");
                    hit = CTSuppressedMatch(sceneID) ?: CTSuppressedMatch(identifier);
                } @catch (__unused NSException *e) {}
                if (hit) { CTFinish(completion); return; }
                ((void(*)(id,SEL,id,id))original)(object,sel,settings,completion);
            });
            MSHookMessageEx(cls,sel,replacement,&original);
            [CTGuardHooks addObject:@"foreground"];
        }
    }
    // DashBoard cập nhật settings scene dashboard/widget. Đồng thời ghi nhận scene.
    {
        Class cls = NSClassFromString(@"FBScene");
        SEL sel = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if (![CTGuardHooks containsObject:@"updateSettings"] && CTHookCompatible(cls,sel,3,'v')) {
            __block IMP original = NULL;
            IMP replacement = imp_implementationWithBlock(^(id object,id settings,id context,id completion) {
                NSString *hit = nil;
                @try { CTNoteScene(object); hit = CTSuppressedMatch(CTReadObject(object,@"identifier")); } @catch (__unused NSException *e) {}
                if (hit) { CTFinish(completion); return; }
                ((void(*)(id,SEL,id,id,id))original)(object,sel,settings,context,completion);
            });
            MSHookMessageEx(cls,sel,replacement,&original);
            [CTGuardHooks addObject:@"updateSettings"];
        }
    }
    CTHookActivation();
}
// Gọi ngay trước khi gửi lệnh kill.
static void CTGuardPrepare(NSString *bundle) {
    CTInstallGuard();
    CTSuppress(bundle);
    CTDestroyScenes(bundle);
}
static void CTGuardInit(void) {
    CTSuppressUntil = [NSMutableDictionary new];
    CTSeenScenes = [NSMapTable strongToWeakObjectsMapTable];
    CTInstallGuard();
}
