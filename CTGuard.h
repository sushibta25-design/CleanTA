#import <dlfcn.h>
// CTGuard (0.1.9) — chỉ chạy trong CarPlayApp.
// Log 0.1.5: sau khi kill, DashBoard vẫn giữ scene <bundle>:dashboard và
// <bundle>:widget, tiếp tục updateSettings rồi foreground lại -> FrontBoard
// spawn process mới (~100ms). Guard này:
//   1. Huỷ mọi FBScene của app trên màn xe TRƯỚC khi kill.
//   2. Trong cửa sổ chặn (15s): bỏ qua foreground/updateSettings của DashBoard
//      cho đúng bundle đó. createScene chỉ ghi log, không chặn (trả nil có thể crash).
// Mọi hook đều kiểm tra ABI lúc chạy; thiếu method thì bỏ qua và ghi log.

static NSMutableDictionary<NSString *, NSNumber *> *CTSuppressUntil;
static NSMutableSet<NSString *> *CTGuardHooks;
static const NSTimeInterval CTSuppressSeconds = 20;
// 0.1.7: log 0.1.6 cho thấy FBSceneManager.scenes không liệt kê được (total=0)
// dù các scene Car[..]:<bundle>:dashboard/widget vẫn tồn tại. Vì vậy tự ghi nhận
// mọi FBScene đi qua hook updateSettings/createScene (giá trị weak).
static NSMapTable<NSString *, id> *CTSeenScenes;
static void CTNoteScene(id scene) {
    NSString *identifier = CTReadObject(scene,@"identifier");
    if (![identifier isKindOfClass:NSString.class] || !CTSeenScenes) return;
    @synchronized (CTSeenScenes) { [CTSeenScenes setObject:scene forKey:identifier]; }
}
static void CTDumpSceneAPI(void) {
    static BOOL done; if (done) return; done = YES;
    for (NSString *name in @[@"FBSceneManager",@"FBScene"]) {
        Class cls = NSClassFromString(name); if (!cls) { CTLog(@"API %@ absent",name); continue; }
        unsigned count = 0; Method *list = class_copyMethodList(cls,&count);
        NSMutableArray *hits = [NSMutableArray new];
        for (unsigned i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(list[i]));
            NSString *low = sel.lowercaseString;
            if ([low containsString:@"destroy"] || [low containsString:@"invalidat"] || [low containsString:@"deactivat"] || [low containsString:@"scenes"] || [low containsString:@"scenewith"]) [hits addObject:sel];
        }
        free(list);
        unsigned ivarCount = 0; Ivar *ivars = class_copyIvarList(cls,&ivarCount);
        NSMutableArray *names = [NSMutableArray new];
        for (unsigned i = 0; i < ivarCount; i++) { const char *n = ivar_getName(ivars[i]); if (n && strstr(n,"cene")) [names addObject:@(n)]; }
        free(ivars);
        CTLog(@"API %@ methods=%@ ivars=%@",name,hits,names);
    }
    // 0.1.9: tìm lớp DashBoard xử lý "death of process" / "nav identifier".
    Dl_info info = {0};
    Class anchor = NSClassFromString(@"DBApplicationSceneViewController");
    if (anchor && dladdr((__bridge void *)anchor,&info) && info.dli_fname) {
        unsigned classCount = 0;
        const char **names = objc_copyClassNamesForImage(info.dli_fname,&classCount);
        NSUInteger logged = 0;
        for (unsigned c = 0; c < classCount && logged < 80; c++) {
            Class cls = objc_getClass(names[c]); if (!cls) continue;
            unsigned count = 0; Method *list = class_copyMethodList(cls,&count);
            NSMutableArray *hits = [NSMutableArray new];
            for (unsigned i = 0; i < count; i++) {
                NSString *sel = NSStringFromSelector(method_getName(list[i]));
                NSString *low = sel.lowercaseString;
                if ([low containsString:@"death"] || [low containsString:@"died"] || [low containsString:@"navigationidentifier"] ||
                    [low containsString:@"navidentifier"] || [low containsString:@"navigationowner"] || [low containsString:@"currentnav"] ||
                    [low containsString:@"processdidexit"] || [low containsString:@"relaunch"]) [hits addObject:sel];
            }
            free(list);
            if (hits.count) { CTLog(@"API_DB %s %@",names[c],hits); logged++; }
        }
        free(names);
        CTLog(@"API_DB scanned image=%s classes=%u",info.dli_fname,classCount);
    } else CTLog(@"API_DB DashBoard image not found");
}

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
    for (NSString *key in @[@"_scenesByID",@"_scenesByIdentifier",@"_scenes"]) {
        if (scenes) break;
        @try { scenes = [manager valueForKey:key]; } @catch (__unused NSException *e) {}
    }
    if ([scenes isKindOfClass:NSSet.class]) return [scenes allObjects];
    if ([scenes isKindOfClass:NSArray.class]) return scenes;
    if ([scenes isKindOfClass:NSDictionary.class]) return [scenes allValues];
    return @[];
}
static NSUInteger CTDestroyScenes(NSString *bundle) {
    CTDumpSceneAPI();
    id manager = CTReadObject(NSClassFromString(@"FBSceneManager"),@"sharedInstance");
    NSMutableDictionary<NSString *, id> *targets = [NSMutableDictionary new];
    NSArray *listed = CTAllScenes();
    for (id scene in listed) {
        NSString *identifier = CTReadObject(scene,@"identifier");
        if (CTIDMatches(identifier,bundle)) targets[identifier] = scene;
    }
    NSUInteger seen = 0;
    @synchronized (CTSeenScenes) {
        seen = CTSeenScenes.count;
        for (NSString *identifier in CTSeenScenes.keyEnumerator.allObjects) {
            id scene = [CTSeenScenes objectForKey:identifier];
            if (scene && CTIDMatches(identifier,bundle)) targets[identifier] = scene;
        }
    }
    CTLog(@"SCENES_MATCH bundle=%@ count=%lu ids=%@ listed=%lu seen=%lu",bundle,(unsigned long)targets.count,targets.allKeys,(unsigned long)listed.count,(unsigned long)seen);
    SEL destroy = NSSelectorFromString(@"destroyScene:withTransitionContext:");
    SEL invalidate = NSSelectorFromString(@"invalidate");
    NSUInteger done = 0;
    for (NSString *identifier in targets) {
        id scene = targets[identifier];
        @try {
            if ([manager respondsToSelector:destroy]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(manager,destroy,identifier,nil);
                done++; CTLog(@"DESTROY manager scene=%@",identifier);
            } else if ([scene respondsToSelector:invalidate]) {
                ((void(*)(id,SEL))objc_msgSend)(scene,invalidate);
                done++; CTLog(@"DESTROY invalidate scene=%@",identifier);
            } else CTLog(@"DESTROY unavailable scene=%@",identifier);
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
                    @try { CTNoteScene(object); } @catch (__unused NSException *e) {}
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
                    id scene = ((id(*)(id,SEL,id,id))original)(object,sel,definition,parameters);
                    @try { CTNoteScene(scene); } @catch (__unused NSException *e) {}
                    return scene;
                });
                MSHookMessageEx(cls,sel,replacement,&original);
                [CTGuardHooks addObject:name]; CTLog(@"GUARD installed create(log-only)");
            } else CTLog(@"GUARD skip create reason=absent_or_ABI_mismatch");
        }
    }
}
// 0.1.9: log hệ thống cho thấy sau khi VML chết, DashBoard ("Current nav identifier
// is: vn.vietmap.live") tạo lại + ACTIVATE scene :widget/:dashboard gửi sang
// CarPlayTemplateUIHost, và CarPlayTemplateUIHost bootstrap lại VML. Đường tạo scene
// không qua createSceneWithDefinition, nên chặn ở bước FBScene activate*.
static NSString *CTBlockedScene(id scene, NSString *entry) {
    NSString *identifier = nil;
    @try { identifier = CTReadObject(scene,@"identifier"); } @catch (__unused NSException *e) {}
    NSString *hit = CTSuppressedMatch(identifier);
    if (hit) CTLog(@"BLOCK %@ bundle=%@ scene=%@",entry,hit,identifier);
    return hit;
}
static void CTFinishBlocks(NSArray *args, NSIndexSet *blockIndexes) {
    [blockIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        id b = i < args.count ? args[i] : nil;
        if (b && b != (id)NSNull.null) ((void(^)(id))b)(nil);
    }];
}
static void CTHookActivation(NSString *className, NSArray<NSString *> *prefixes) {
    Class cls = NSClassFromString(className);
    if (!cls) { CTLog(@"GUARD activate class absent %@",className); return; }
    unsigned count = 0; Method *list = class_copyMethodList(cls,&count);
    for (unsigned i = 0; i < count; i++) {
        SEL sel = method_getName(list[i]);
        NSString *selName = NSStringFromSelector(sel);
        BOOL match = NO;
        for (NSString *p in prefixes) if ([selName hasPrefix:p]) { match = YES; break; }
        if (!match) continue;
        NSString *key = [NSString stringWithFormat:@"activate %@ %@",className,selName];
        if ([CTGuardHooks containsObject:key]) continue;
        unsigned argc = method_getNumberOfArguments(list[i]) - 2;
        char type[128] = {0}; method_getReturnType(list[i],type,sizeof(type));
        BOOL ok = type[0] == 'v' && argc <= 3;
        NSMutableIndexSet *blocks = [NSMutableIndexSet new];
        for (unsigned a = 0; ok && a < argc; a++) {
            method_getArgumentType(list[i],a+2,type,sizeof(type));
            if (type[0] != '@') ok = NO; else if (type[1] == '?') [blocks addIndex:a];
        }
        if (!ok) { CTLog(@"GUARD activate skip %@ (ABI)",key); continue; }
        __block IMP original = NULL; IMP replacement = NULL;
        NSString *entry = selName;
        if (argc == 0) replacement = imp_implementationWithBlock(^(id o) {
            if (CTBlockedScene(o,entry)) return;
            ((void(*)(id,SEL))original)(o,sel); });
        else if (argc == 1) replacement = imp_implementationWithBlock(^(id o,id a) {
            if (CTBlockedScene(o,entry)) { CTFinishBlocks(@[a ?: NSNull.null],blocks); return; }
            ((void(*)(id,SEL,id))original)(o,sel,a); });
        else if (argc == 2) replacement = imp_implementationWithBlock(^(id o,id a,id b) {
            if (CTBlockedScene(o,entry)) { CTFinishBlocks(@[a ?: NSNull.null,b ?: NSNull.null],blocks); return; }
            ((void(*)(id,SEL,id,id))original)(o,sel,a,b); });
        else replacement = imp_implementationWithBlock(^(id o,id a,id b,id c) {
            if (CTBlockedScene(o,entry)) { CTFinishBlocks(@[a ?: NSNull.null,b ?: NSNull.null,c ?: NSNull.null],blocks); return; }
            ((void(*)(id,SEL,id,id,id))original)(o,sel,a,b,c); });
        MSHookMessageEx(cls,sel,replacement,&original);
        [CTGuardHooks addObject:key]; CTLog(@"GUARD installed %@",key);
    }
    free(list);
}
// Gọi ngay trước khi gửi lệnh kill.
static void CTGuardPrepare(NSString *bundle) {
    CTInstallGuard();
    CTHookActivation(@"FBScene",@[@"activate",@"_activate"]);
    CTSuppress(bundle);
    CTDestroyScenes(bundle);
}
static void CTGuardInit(void) {
    CTSuppressUntil = [NSMutableDictionary new];
    CTSeenScenes = [NSMapTable strongToWeakObjectsMapTable];
    CTInstallGuard();
    CTHookActivation(@"FBScene",@[@"activate",@"_activate"]);
}
