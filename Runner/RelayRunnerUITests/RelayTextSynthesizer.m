#import "RelayTextSynthesizer.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

// Private XCTest interfaces (XCUIAutomation.framework in Xcode 27), declared as protocols so the runner
// never links against the private class symbols. `XCUIElement.typeText` builds the same record
// (`_XCUITypeTextWithSpeedEvent`).

@protocol RelayXCTextEventPath <NSObject>
- (instancetype)initForTextInput;
- (void)typeText:(NSString *)text atOffset:(double)offset typingSpeed:(NSUInteger)typingSpeed shouldRedact:(BOOL)shouldRedact;
- (void)typeKey:(NSString *)key modifiers:(unsigned long long)modifiers atOffset:(double)offset;
@end

@protocol RelayXCTextEventRecord <NSObject>
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(id<RelayXCTextEventPath>)path;
@end

@protocol RelayXCTextEventSynthesizing <NSObject>
- (void)synthesizeEvent:(id<RelayXCTextEventRecord>)event
             completion:(void (^)(BOOL result, NSError *_Nullable error))completion;
@end

@protocol RelayXCTextDeviceEventSynthesizer <NSObject>
- (id<RelayXCTextEventSynthesizing>)eventSynthesizer;
@end

static NSString *const RelayTextSynthesizerErrorDomain = @"RelayTextSynthesizer";

@implementation RelayTextSynthesizer

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

+ (nullable NSString *)probe {
    if ([NSProcessInfo.processInfo.environment[@"RELAY_DISABLE_PRIVATE_TYPING"] isEqualToString:@"1"]) {
        return @"disabled by RELAY_DISABLE_PRIVATE_TYPING=1";
    }
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    if (pathClass == Nil) {
        return @"XCPointerEventPath not found";
    }
    if (recordClass == Nil) {
        return @"XCSynthesizedEventRecord not found";
    }
    for (NSString *name in @[@"initForTextInput", @"typeText:atOffset:typingSpeed:shouldRedact:"]) {
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
    id synthesizer = [(id<RelayXCTextDeviceEventSynthesizer>)device eventSynthesizer];
    if (synthesizer == nil) {
        return @"XCUIDevice.eventSynthesizer is nil";
    }
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        return [NSString stringWithFormat:@"%@ does not respond to synthesizeEvent:completion:", [synthesizer class]];
    }
    return nil;
}

+ (BOOL)isKeyAvailable {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        available = self.isAvailable
            && [NSClassFromString(@"XCPointerEventPath") instancesRespondToSelector:@selector(typeKey:modifiers:atOffset:)];
    });
    return available;
}

+ (BOOL)synthesizeKey:(NSString *)key
            modifiers:(NSUInteger)modifiers
           completion:(void (^)(NSError *_Nullable))completion
                error:(NSError **)error {
    if (!self.isKeyAvailable || key.length == 0) {
        if (error != NULL) {
            NSString *reason = self.isKeyAvailable ? @"key must not be empty"
                : (self.unavailableReason ?: @"XCPointerEventPath does not respond to typeKey:modifiers:atOffset:");
            *error = [NSError errorWithDomain:RelayTextSynthesizerErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
    id<RelayXCTextEventPath> path = [(id<RelayXCTextEventPath>)[NSClassFromString(@"XCPointerEventPath") alloc] initForTextInput];
    [path typeKey:key modifiers:modifiers atOffset:0];
    [self synthesizePath:path name:@"relay key" completion:completion];
    return YES;
}

+ (void)synthesizePath:(id<RelayXCTextEventPath>)path
                  name:(NSString *)name
            completion:(void (^)(NSError *_Nullable))completion {
    id<RelayXCTextEventRecord> record = [(id<RelayXCTextEventRecord>)[NSClassFromString(@"XCSynthesizedEventRecord") alloc]
        initWithName:name
        interfaceOrientation:UIInterfaceOrientationPortrait];
    [record addPointerEventPath:path];

    id<RelayXCTextEventSynthesizing> synthesizer = [(id<RelayXCTextDeviceEventSynthesizer>)XCUIDevice.sharedDevice eventSynthesizer];
    [synthesizer synthesizeEvent:record completion:^(BOOL result, NSError *_Nullable invokeError) {
        if (!result && invokeError == nil) {
            invokeError = [NSError errorWithDomain:RelayTextSynthesizerErrorDomain
                                              code:2
                                          userInfo:@{NSLocalizedDescriptionKey: @"event synthesis reported failure"}];
        }
        completion(result ? nil : invokeError);
    }];
}

+ (BOOL)synthesizeText:(NSString *)text
           typingSpeed:(NSUInteger)typingSpeed
            completion:(void (^)(NSError *_Nullable))completion
                 error:(NSError **)error {
    NSString *reason = self.unavailableReason;
    if (reason == nil && text.length == 0) {
        reason = @"text must not be empty";
    }
    if (reason != nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:RelayTextSynthesizerErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }

    id<RelayXCTextEventPath> path = [(id<RelayXCTextEventPath>)[NSClassFromString(@"XCPointerEventPath") alloc] initForTextInput];
    [path typeText:text atOffset:0 typingSpeed:typingSpeed shouldRedact:NO];
    [self synthesizePath:path name:@"relay type" completion:completion];
    return YES;
}

@end
