#import "RelayTouchSynthesizer.h"

#import <XCTest/XCTest.h>

// Private XCTest interfaces (XCUIAutomation.framework in Xcode 27). Declared as protocols so the
// runner never links against the private class symbols.

@protocol RelayXCPointerEventPath <NSObject>
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end

@protocol RelayXCSynthesizedEventRecord <NSObject>
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(UIInterfaceOrientation)orientation;
- (instancetype)initWithName:(NSString *)name
                   displayID:(unsigned long long)displayID
        interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(id<RelayXCPointerEventPath>)path;
@end

@protocol RelayXCUIEventSynthesizing <NSObject>
- (void)synthesizeEvent:(id<RelayXCSynthesizedEventRecord>)event
             completion:(void (^)(BOOL result, NSError *_Nullable error))completion;
@end

@protocol RelayXCUIDeviceEventSynthesizer <NSObject>
- (id<RelayXCUIEventSynthesizing>)eventSynthesizer;
@end

static NSString *const RelayTouchSynthesizerErrorDomain = @"RelayTouchSynthesizer";

@implementation RelayTouchSynthesizer

+ (NSString *)unavailableReason {
    static NSString *reason;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reason = [self probe];
    });
    return reason;
}

+ (BOOL)isAvailable {
    return self.unavailableReason == nil;
}

+ (BOOL)supportsDisplayID {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    return self.isAvailable
        && [recordClass instancesRespondToSelector:@selector(initWithName:displayID:interfaceOrientation:)];
}

+ (nullable NSString *)probe {
    if ([NSProcessInfo.processInfo.environment[@"RELAY_DISABLE_PRIVATE_TOUCH"] isEqualToString:@"1"]) {
        return @"disabled by RELAY_DISABLE_PRIVATE_TOUCH=1";
    }
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    if (pathClass == Nil) {
        return @"XCPointerEventPath not found";
    }
    if (recordClass == Nil) {
        return @"XCSynthesizedEventRecord not found";
    }
    for (NSString *name in @[@"initForTouchAtPoint:offset:", @"moveToPoint:atOffset:", @"liftUpAtOffset:"]) {
        if (![pathClass instancesRespondToSelector:NSSelectorFromString(name)]) {
            return [NSString stringWithFormat:@"XCPointerEventPath does not respond to %@", name];
        }
    }
    for (NSString *name in @[@"initWithName:interfaceOrientation:", @"addPointerEventPath:"]) {
        if (![recordClass instancesRespondToSelector:NSSelectorFromString(name)]) {
            return [NSString stringWithFormat:@"XCSynthesizedEventRecord does not respond to %@", name];
        }
    }
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![device respondsToSelector:@selector(eventSynthesizer)]) {
        return @"XCUIDevice does not respond to eventSynthesizer";
    }
    id synthesizer = [(id<RelayXCUIDeviceEventSynthesizer>)device eventSynthesizer];
    if (synthesizer == nil) {
        return @"XCUIDevice.eventSynthesizer is nil";
    }
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        return [NSString stringWithFormat:@"%@ does not respond to synthesizeEvent:completion:", [synthesizer class]];
    }
    return nil;
}

+ (BOOL)synthesizeTouchWithPoints:(NSArray<NSValue *> *)points
                          offsets:(NSArray<NSNumber *> *)offsets
                       liftOffset:(NSTimeInterval)liftOffset
             interfaceOrientation:(UIInterfaceOrientation)orientation
                        displayID:(nullable NSNumber *)displayID
                       completion:(void (^)(NSError *_Nullable))completion
                            error:(NSError **)error {
    NSString *reason = self.unavailableReason;
    if (reason == nil && (points.count == 0 || offsets.count != points.count - 1)) {
        reason = @"points must be non-empty and offsets must have one entry per move";
    }
    if (reason == nil && displayID != nil && !self.supportsDisplayID) {
        reason = @"XCSynthesizedEventRecord does not respond to initWithName:displayID:interfaceOrientation:";
    }
    if (reason != nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:RelayTouchSynthesizerErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }

    id<RelayXCPointerEventPath> path = [(id<RelayXCPointerEventPath>)[NSClassFromString(@"XCPointerEventPath") alloc]
        initForTouchAtPoint:points[0].CGPointValue
                     offset:0];
    for (NSUInteger index = 1; index < points.count; index++) {
        [path moveToPoint:points[index].CGPointValue atOffset:offsets[index - 1].doubleValue];
    }
    [path liftUpAtOffset:liftOffset];

    id<RelayXCSynthesizedEventRecord> record = [NSClassFromString(@"XCSynthesizedEventRecord") alloc];
    record = displayID != nil
        ? [record initWithName:@"relay touch" displayID:displayID.unsignedLongLongValue interfaceOrientation:orientation]
        : [record initWithName:@"relay touch" interfaceOrientation:orientation];
    [record addPointerEventPath:path];

    id<RelayXCUIEventSynthesizing> synthesizer = [(id<RelayXCUIDeviceEventSynthesizer>)XCUIDevice.sharedDevice eventSynthesizer];
    [synthesizer synthesizeEvent:record completion:^(BOOL result, NSError *_Nullable invokeError) {
        if (!result && invokeError == nil) {
            invokeError = [NSError errorWithDomain:RelayTouchSynthesizerErrorDomain
                                              code:2
                                          userInfo:@{NSLocalizedDescriptionKey: @"event synthesis reported failure"}];
        }
        completion(result ? nil : invokeError);
    }];
    return YES;
}

@end
