// CTUtil — tiện ích dùng chung.
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// Gọi getter không tham số trả object; kiểm tra chữ ký trước khi gọi.
static id CTReadObject(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,selector);
}
