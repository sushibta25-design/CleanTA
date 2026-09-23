// Diagnostic-only observers: never launch, terminate, or retry an application.
#import <objc/runtime.h>
#import <substrate.h>
#import <sys/sysctl.h>
#import <sys/stat.h>

static int CTPid(NSString *bundle);
static unsigned CTExists(int pid);
static dispatch_queue_t CTLogQueue;
static dispatch_source_t CTTraceTimer;
static NSTimeInterval CTTraceDeadline;
static NSMutableSet<NSString *> *CTWatched;
static NSMutableDictionary<NSString *, NSString *> *CTLastStates;
static BOOL CTTracing;
static int CTTraceToken = -1;

static void CTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void CTLog(NSString *format, ...) {
    if (!CTLogQueue) return;
    va_list args; va_start(args,format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSTimeInterval time = NSDate.date.timeIntervalSince1970;
    dispatch_async(CTLogQueue, ^{
        @autoreleasepool { @try {
            NSString *dir = @"/var/mobile/Library/Logs/CleanTA";
            NSFileManager *fm = NSFileManager.defaultManager;
            NSError *error = nil;
            if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
                NSLog(@"[CleanTA] log directory failed: %@",error); return;
            }
            NSString *role = [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"] ? @"SpringBoard" : @"CarPlay";
            NSString *path = [dir stringByAppendingPathComponent:[role stringByAppendingString:@".log"]];
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            if ([attrs fileSize] >= 512*1024) {
                NSString *old = [path stringByAppendingString:@".1"];
                [fm removeItemAtPath:old error:nil];
                if (![fm moveItemAtPath:path toPath:old error:&error]) {
                    NSLog(@"[CleanTA] log rotation failed: %@",error); return;
                }
            }
            if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
            NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!file) { NSLog(@"[CleanTA] cannot write %@",path); return; }
            NSString *line = [NSString stringWithFormat:@"%.3f pid=%d %@\n",time,getpid(),message];
            [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
        } @catch (NSException *exception) { NSLog(@"[CleanTA] logger exception %@",exception.name); } }
    });
}
static NSString *CTProcess(int pid) {
    if (pid <= 1) return [NSString stringWithFormat:@"apiPID=%d",pid];
    unsigned exists = CTExists(pid);
    struct kinfo_proc info = {0}; size_t length = sizeof(info);
    int mib[] = {CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};
    int result = sysctl(mib,4,&info,&length,NULL,0);
    int saved = errno;
    if (result == 0 && length > 0) {
        return [NSString stringWithFormat:@"pid=%d exists=%u ppid=%d state=%d start=%lld.%06d name=%s",pid,exists,info.kp_eproc.e_ppid,info.kp_proc.p_stat,(long long)info.kp_proc.p_starttime.tv_sec,(int)info.kp_proc.p_starttime.tv_usec,info.kp_proc.p_comm];
    }
    return [NSString stringWithFormat:@"pid=%d exists=%u sysctl=%d errno=%d bytes=%lu",pid,exists,result,result ? saved : 0,(unsigned long)length];
}
#import "CTSceneDiagnostics.h"
static void CTStartTrace(void) {
    // All trace state and polling live on the main queue. Hook filtering uses a lock.
    NSCAssert(NSThread.isMainThread,@"trace requires main queue");
    CTTraceDeadline = NSProcessInfo.processInfo.systemUptime + 60;
    @synchronized (CTWatched) { CTTracing = YES; }
    [CTLastStates removeAllObjects];
    CTSceneTraceBegin();
    CTLog(@"TRACE_BEGIN version=0.1.6 duration=60s interval=250ms exists:0=absent,1=present,2=unknown; ppid is NOT proof of launch requester");
    if (CTTraceTimer) return;
    CTTraceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(CTTraceTimer,DISPATCH_TIME_NOW,250*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(CTTraceTimer, ^{
        if (NSProcessInfo.processInfo.systemUptime >= CTTraceDeadline) {
            @synchronized (CTWatched) { CTTracing = NO; }
            CTLog(@"TRACE_END"); dispatch_source_cancel(CTTraceTimer); CTTraceTimer = nil; return;
        }
        NSArray *bundles;
        @synchronized (CTWatched) { bundles = CTWatched.allObjects; }
        for (NSString *bundle in bundles) {
            @try {
                NSString *state = CTProcess(CTPid(bundle));
                if (![CTLastStates[bundle] isEqual:state]) {
                    CTLog(@"PROCESS_CHANGE bundle=%@ %@",bundle,state); CTLastStates[bundle] = state;
                }
            } @catch (NSException *e) { CTLog(@"POLL exception=%@ bundle=%@",e.name,bundle); }
        }
    });
    dispatch_resume(CTTraceTimer);
}
static void CTWatch(NSString *bundle) {
    @synchronized (CTWatched) { [CTWatched addObject:bundle]; }
    CTStartTrace();
}
static void (*CTOriginalOpen)(id,SEL,id,id,id);
static void CTOpen(id self,SEL selector,id bundle,id options,id completion) {
    @try {
        BOOL record = NO;
        @synchronized (CTWatched) { record = CTTracing && [bundle isKindOfClass:NSString.class] && [CTWatched containsObject:bundle]; }
        if (record) {
            // Only option keys and stack symbols: no URLs, coordinates or option values.
            NSArray *keys = [options isKindOfClass:NSDictionary.class] ? [options allKeys] : @[];
            CTLog(@"OPEN_REQUEST bundle=%@ optionKeys=%@ stack=%@",bundle,keys,NSThread.callStackSymbols);
        }
    } @catch (NSException *e) { CTLog(@"OPEN_OBSERVER exception=%@",e.name); }
    CTOriginalOpen(self,selector,bundle,options,completion);
}
static void CTDiagnosticsInit(void) {
    CTLogQueue = dispatch_queue_create("com.sushibta.cleanta.log",DISPATCH_QUEUE_SERIAL);
    CTWatched = [NSMutableSet setWithArray:@[@"com.google.Maps",@"vn.vietmap.live"]];
    CTLastStates = [NSMutableDictionary new];
    CTLog(@"INIT version=0.1.6 bundle=%@ iOS=%@",NSBundle.mainBundle.bundleIdentifier,UIDevice.currentDevice.systemVersion);
    // Runtime ABI validation: skip unknown signatures rather than guessing a private API.
    Class cls = NSClassFromString(@"FBSSystemService");
    SEL selector = NSSelectorFromString(@"openApplication:options:withResult:");
    Method method = class_getInstanceMethod(cls,selector);
    BOOL compatible = method && method_getNumberOfArguments(method) == 5;
    if (compatible) {
        char type[64] = {0}; method_getReturnType(method,type,sizeof(type)); compatible = type[0] == 'v';
        for (unsigned i=2;i<5 && compatible;i++) { method_getArgumentType(method,i,type,sizeof(type)); compatible = type[0] == '@'; }
    }
    if (compatible) {
        MSHookMessageEx(cls,selector,(IMP)CTOpen,(IMP *)&CTOriginalOpen);
        CTLog(@"HOOK installed FBSSystemService openApplication:options:withResult:");
    } else CTLog(@"HOOK unavailable/signature mismatch; launch requester may be outside observation coverage");
    CTLog(@"COVERAGE SpringBoard and CarPlay only; missing OPEN_REQUEST does not exclude a launch via another API/process");
    if ([NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) {
        if (notify_register_dispatch("com.sushibta.cleanta.trace.v1",&CTTraceToken,dispatch_get_main_queue(),^(int token) { CTStartTrace(); }) != NOTIFY_STATUS_OK) CTLog(@"TRACE notification registration failed");
    }
}
