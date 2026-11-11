#import "RelayURLOpener.h"

// Private XCTest interfaces (XCUIAutomation.framework in Xcode 27), declared as a protocol so the runner
// never links against the private class symbols. `XCUISystem.openURL:` calls the first method, and
// `XCUIApplication.openURL:` the second, before they wait for the app to idle.

@protocol RelayXCTRunnerDaemonSession <NSObject>
+ (instancetype)sharedSession;
- (void)openDefaultApplicationForURL:(NSURL *)url completion:(void (^)(BOOL result, NSError *_Nullable error))completion;
- (void)openURL:(NSURL *)url
    usingApplication:(NSString *)bundleID
          completion:(void (^)(BOOL result, NSError *_Nullable error))completion;
@end

static NSString *const RelayURLOpenerErrorDomain = @"RelayURLOpener";

@implementation RelayURLOpener

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
    if ([NSProcessInfo.processInfo.environment[@"RELAY_DISABLE_PRIVATE_OPEN"] isEqualToString:@"1"]) {
        return @"disabled by RELAY_DISABLE_PRIVATE_OPEN=1";
    }
    Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    if (sessionClass == Nil) {
        return @"XCTRunnerDaemonSession not found";
    }
    if (![sessionClass respondsToSelector:@selector(sharedSession)]) {
        return @"XCTRunnerDaemonSession does not respond to sharedSession";
    }
    for (NSString *name in @[@"openDefaultApplicationForURL:completion:", @"openURL:usingApplication:completion:"]) {
        if (![sessionClass instancesRespondToSelector:NSSelectorFromString(name)]) {
            return [NSString stringWithFormat:@"XCTRunnerDaemonSession does not respond to %@", name];
        }
    }
    return nil;
}

+ (void)openURL:(NSURL *)url
       bundleID:(nullable NSString *)bundleID
     completion:(void (^)(NSError *_Nullable error))completion {
    NSString *reason = self.unavailableReason;
    if (reason != nil) {
        completion([NSError errorWithDomain:RelayURLOpenerErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: reason}]);
        return;
    }
    id<RelayXCTRunnerDaemonSession> session = [(Class<RelayXCTRunnerDaemonSession>)NSClassFromString(@"XCTRunnerDaemonSession") sharedSession];
    void (^done)(BOOL, NSError *) = ^(BOOL result, NSError *_Nullable error) {
        if (!result && error == nil) {
            error = [NSError errorWithDomain:RelayURLOpenerErrorDomain
                                        code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"the URL was not opened, and no reason was given"}];
        }
        completion(result ? nil : error);
    };
    if (bundleID != nil) {
        [session openURL:url usingApplication:bundleID completion:done];
    } else {
        [session openDefaultApplicationForURL:url completion:done];
    }
}

@end
