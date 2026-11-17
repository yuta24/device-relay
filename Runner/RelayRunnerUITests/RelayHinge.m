#import "RelayHinge.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>

// Resolved at runtime, as with the runner's other private APIs. Events stay inside the guest.
typedef CFTypeRef (*RHCreateEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const uint8_t *, CFIndex, uint32_t);
typedef CFTypeRef (*RHCreateClient)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*RHDispatch)(CFTypeRef, CFTypeRef);
typedef CFDataRef (*RHSerialize)(CFTypeRef, CFOptionFlags);
static RHCreateEvent createEvent;
static RHCreateClient createClient;
static RHDispatch sendEvent;
static RHSerialize serialize;

@implementation RelayHinge

+ (BOOL)hasHinge {
#if TARGET_OS_SIMULATOR
    dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_NOW);
    Class cls = NSClassFromString(@"CMAngleManager");
    SEL available = NSSelectorFromString(@"isAvailable");
    return cls && [cls respondsToSelector:available] && ((BOOL (*)(id, SEL))objc_msgSend)(cls, available);
#else
    return NO;
#endif
}

+ (NSString *)unavailableReason {
#if !TARGET_OS_SIMULATOR
    return @"hinge events are available only on simulators";
#else
    if (![self hasHinge]) return @"CMAngleManager is unavailable; this simulator has no hinge";
    Class cls = NSClassFromString(@"CMAngleManager");
    for (NSString *name in @[@"startAngleUpdatesToQueue:handler:", @"stopAngleUpdates"]) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(name)]) return [@"CMAngleManager is missing " stringByAppendingString:name];
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (lib) {
            createEvent = (RHCreateEvent)dlsym(lib, "IOHIDEventCreateVendorDefinedEvent");
            createClient = (RHCreateClient)dlsym(lib, "IOHIDEventSystemClientCreateWithType");
            sendEvent = (RHDispatch)dlsym(lib, "IOHIDEventSystemClientDispatchEvent");
            serialize = (RHSerialize)dlsym(lib, "IOCFSerialize");
        }
    });
    if (!createEvent || !createClient || !sendEvent || !serialize) return @"guest HID event functions are unavailable";
    return nil;
#endif
}

+ (NSDictionary *)failure:(NSString *)code reason:(NSString *)reason {
    return @{@"ok": @NO, @"code": code, @"error": reason};
}

// Start monitoring before dispatch. All handler state is protected because stopAngleUpdates may
// return while a callback is queued. A late callback cannot alter the returned snapshot.
+ (NSDictionary *)sampleTarget:(double)target send:(void (^_Nullable)(void))send {
    NSString *reason = [self unavailableReason];
    if (reason) return [self failure:@"hinge_unavailable" reason:reason];
    id manager = [[NSClassFromString(@"CMAngleManager") alloc] init];
    if (!manager) return [self failure:@"hinge_unavailable" reason:@"cannot create CMAngleManager"];
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_semaphore_t reached = dispatch_semaphore_create(0);
    __block BOOL finished = NO, valid = NO, sent = NO, matched = NO;
    __block double angle = NAN, mechanical = NAN;
    void (^handler)(id) = ^(id sample) {
        [lock lock];
        if (!finished && !matched && [sample respondsToSelector:NSSelectorFromString(@"angleDegrees")] &&
            [sample respondsToSelector:NSSelectorFromString(@"mechanicalAngleDegrees")]) {
            angle = ((float (*)(id, SEL))objc_msgSend)(sample, NSSelectorFromString(@"angleDegrees"));
            mechanical = ((float (*)(id, SEL))objc_msgSend)(sample, NSSelectorFromString(@"mechanicalAngleDegrees"));
            if (isfinite(angle) && isfinite(mechanical)) {
                if (!valid) { valid = YES; dispatch_semaphore_signal(ready); }
                if (sent && (isnan(target) || fabs(mechanical - target) <= 0.5)) {
                    matched = YES;
                    dispatch_semaphore_signal(reached);
                }
            }
        }
        [lock unlock];
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(manager, NSSelectorFromString(@"startAngleUpdatesToQueue:handler:"), queue, handler);
    // A valid mechanical reading is required before any event can be sent.
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    [lock lock];
    BOOL canSend = valid;
    matched = valid && (isnan(target) || fabs(mechanical - target) <= 0.5);
    BOOL alreadyAtTarget = matched && !isnan(target);
    sent = canSend;
    [lock unlock];
    if (canSend && send && !alreadyAtTarget) {
        send();
        if (!isnan(target)) dispatch_semaphore_wait(reached, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }
    [lock lock];
    finished = YES;
    NSDictionary *result;
    if (!valid) result = [self failure:@"hinge_unavailable" reason:@"no valid mechanical hinge reading; nothing was sent"];
    else if (send && !matched) result = [self failure:@"hinge_failed" reason:@"mechanical hinge angle did not reach the target within 3 seconds"];
    else result = @{@"ok": @YES, @"angle": @(angle), @"mechanicalAngle": @(mechanical)};
    if (valid && ![result[@"ok"] boolValue]) {
        NSMutableDictionary *failure = [result mutableCopy];
        failure[@"angle"] = @(angle);
        failure[@"mechanicalAngle"] = @(mechanical);
        result = failure;
    }
    [lock unlock];
    ((void (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"stopAngleUpdates"));
    return result;
}

+ (NSDictionary *)readAngle { return [self sampleTarget:NAN send:nil]; }

+ (NSDictionary *)sendSource:(NSString *)source type:(NSString *)type value:(id)value target:(double)target {
    NSString *reason = [self unavailableReason];
    if (reason) return [self failure:@"hinge_unavailable" reason:reason];
    CFTypeRef client = createClient(NULL, 4, NULL);
    if (!client) return [self failure:@"hinge_unavailable" reason:@"cannot create guest HID client; nothing was sent"];
    NSDictionary *payload = @{@"provider": @"com.apple.Virtualization.VirtualMachines", @"source": source, @"type": type, @"value": value};
    CFDataRef data = serialize((__bridge CFTypeRef)payload, 1);
    CFTypeRef event = data ? createEvent(NULL, mach_absolute_time(), 0xFF61, 0x5B, 0, CFDataGetBytePtr(data), CFDataGetLength(data), 0) : NULL;
    NSDictionary *result = event ? [self sampleTarget:target send:^{ sendEvent(client, event); }]
        : [self failure:@"hinge_unavailable" reason:@"cannot create vendor event; nothing was sent"];
    if (event) CFRelease(event);
    if (data) CFRelease(data);
    CFRelease(client);
    return result;
}

+ (NSDictionary *)setAngle:(double)degrees {
    if (!isfinite(degrees) || degrees < 0 || degrees > 180) return [self failure:@"invalid_request" reason:@"angle must be in 0...180"];
    return [self sendSource:@"hinge-slider-control" type:@"range" value:@(degrees) target:degrees];
}

+ (NSDictionary *)setOrientation:(NSString *)value {
    if (![@[@"portrait", @"pud", @"landscape-left", @"landscape-right"] containsObject:value])
        return [self failure:@"invalid_request" reason:@"invalid orientation event value"];
    return [self sendSource:@"orientation-picker-control" type:@"enum" value:value target:NAN];
}
@end
