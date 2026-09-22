// Observe a bounded set of scene entry points. Never call activation ourselves.
#import <mach-o/dyld.h>
static NSUInteger CTSceneEventCount;
static NSMutableSet<NSString *> *CTSceneHooks;
static id CTReadObject(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,selector);
}
static NSString *CTSceneIdentity(id object) {
    if (!object) return @"nil";
    NSMutableArray *parts = [NSMutableArray arrayWithObject:NSStringFromClass([object class])];
    // Read identifiers only, never arbitrary object descriptions/settings values.
    for (NSString *key in @[@"bundleIdentifier",@"applicationIdentifier",@"sceneID",@"identifier"]) {
        @try {
            id value = CTReadObject(object,key);
            if ([value isKindOfClass:NSString.class]) [parts addObject:[NSString stringWithFormat:@"%@=%@",key,[value substringToIndex:MIN((NSUInteger)200,[value length])]]];
        } @catch (__unused NSException *e) {}
    }
    return [parts componentsJoinedByString:@" "];
}
static void CTSceneEvent(NSString *entry,id object,id a,id b) {
    @try {
        @synchronized (CTWatched) {
            if (!CTTracing || CTSceneEventCount >= 300) return;
            CTSceneEventCount++;
        }
        CTLog(@"SCENE_CALL %@ self={%@} arg1={%@} arg2={%@} stack=%@",entry,CTSceneIdentity(object),CTSceneIdentity(a),CTSceneIdentity(b),NSThread.callStackSymbols);
    } @catch (NSException *e) { CTLog(@"SCENE_OBSERVER exception=%@",e.name); }
}
static void CTInstallSceneObservers(void) {
    if (!CTSceneHooks) CTSceneHooks = [NSMutableSet new];
    // v/@ = exact return ABI; remaining arguments must all be objects/blocks.
    NSArray *specs = @[
        @[@"DBApplicationSceneViewController",@"foregroundSceneWithSettings:completion:",@"v",@2],
        @[@"DBApplicationSceneViewController",@"backgroundSceneWithCompletion:",@"v",@1],
        @[@"DBApplicationSceneViewController",@"sceneManager:didDestroyScene:",@"v",@2],
        @[@"FBSceneManager",@"createSceneWithDefinition:initialParameters:",@"@",@2],
        @[@"FBSScene",@"updateSettings:withTransitionContext:completion:",@"v",@3],
        @[@"FBScene",@"updateSettings:withTransitionContext:completion:",@"v",@3]
    ];
    for (NSArray *spec in specs) {
        NSString *name = [NSString stringWithFormat:@"%@ %@",spec[0],spec[1]];
        if ([CTSceneHooks containsObject:name]) continue;
        Class cls = NSClassFromString(spec[0]); SEL sel = NSSelectorFromString(spec[1]);
        Method method = class_getInstanceMethod(cls,sel);
        unsigned count = [spec[3] unsignedIntValue];
        char type[128] = {0}; BOOL compatible = method && method_getNumberOfArguments(method) == count+2;
        if (compatible) { method_getReturnType(method,type,sizeof(type)); compatible = type[0] == [spec[2] UTF8String][0]; }
        for (unsigned i=2;compatible && i<count+2;i++) { method_getArgumentType(method,i,type,sizeof(type)); compatible = type[0] == '@'; }
        if (!compatible) { CTLog(@"SCENE_HOOK skip %@ reason=absent_or_ABI_mismatch",name); continue; }
        __block IMP original = NULL; IMP replacement = NULL;
        if ([spec[2] isEqual:@"@"]) {
            replacement = imp_implementationWithBlock(^id(id object,id a,id b) {
                CTSceneEvent(name,object,a,b);
                return ((id(*)(id,SEL,id,id))original)(object,sel,a,b);
            });
        } else if (count == 1) {
            replacement = imp_implementationWithBlock(^(id object,id a) {
                CTSceneEvent(name,object,nil,nil);
                ((void(*)(id,SEL,id))original)(object,sel,a);
            });
        } else if (count == 2) {
            replacement = imp_implementationWithBlock(^(id object,id a,id b) {
                CTSceneEvent(name,object,a,b);
                ((void(*)(id,SEL,id,id))original)(object,sel,a,b);
            });
        } else {
            replacement = imp_implementationWithBlock(^(id object,id a,id b,id c) {
                CTSceneEvent(name,object,a,b);
                ((void(*)(id,SEL,id,id,id))original)(object,sel,a,b,c);
            });
        }
        MSHookMessageEx(cls,sel,replacement,&original);
        [CTSceneHooks addObject:name]; CTLog(@"SCENE_HOOK installed %@",name);
    }
}
static void CTSceneTraceBegin(void) {
    CTInstallSceneObservers();
    @synchronized (CTWatched) { CTSceneEventCount = 0; }
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        const char *raw = _dyld_get_image_name(i); if (!raw) continue;
        NSString *path = [NSString stringWithUTF8String:raw];
        if ([path containsString:@"MobileSubstrate"] || [path containsString:@"TweakInject"] || [path containsString:@"/var/jb/"])
            CTLog(@"LOADED_IMAGE %@",path.lastPathComponent);
    }
    CTLog(@"SCENE_COVERAGE installed=%@ maxEvents=300; missing events do not exclude other activation paths",CTSceneHooks.allObjects);
}
