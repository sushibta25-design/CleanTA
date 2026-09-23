// CTUtil — tiện ích dùng chung. Log gọn: chỉ sự kiện đóng app/lỗi, tối đa 128 KB.
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static dispatch_queue_t CTLogQueue;

static void CTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void CTLog(NSString *format, ...) {
    if (!CTLogQueue) return;
    va_list args; va_start(args,format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSTimeInterval time = NSDate.date.timeIntervalSince1970;
    BOOL springboard = [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"];
    dispatch_async(CTLogQueue, ^{
        @autoreleasepool { @try {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *dir = @"/var/mobile/Library/Logs/CleanTA";
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *path = [dir stringByAppendingPathComponent:springboard ? @"SpringBoard.log" : @"CarPlay.log"];
            if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 128 * 1024) [fm removeItemAtPath:path error:nil];
            if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
            NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
            [file seekToEndOfFile];
            [file writeData:[[NSString stringWithFormat:@"%.3f %@\n",time,message] dataUsingEncoding:NSUTF8StringEncoding]];
            [file closeFile];
        } @catch (__unused NSException *e) {} }
    });
}
static void CTLogInit(void) {
    CTLogQueue = dispatch_queue_create("com.sushibta.cleanta.log",DISPATCH_QUEUE_SERIAL);
}
// Gọi getter không tham số, trả object; kiểm tra chữ ký trước khi gọi.
static id CTReadObject(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,selector);
}
