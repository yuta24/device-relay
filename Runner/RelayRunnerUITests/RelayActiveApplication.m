#import "RelayActiveApplication.h"

#import <XCTest/XCTest.h>

// Private XCTest interfaces (XCUIAutomation.framework and XCTAutomationSupport.framework in Xcode 27).
// Declared as protocols so the runner never links against the private class symbols.

@protocol RelayXCAccessibilityElement <NSObject>
- (pid_t)processIdentifier;
@end

@protocol RelayXCAXClient <NSObject>
- (NSArray<id<RelayXCAccessibilityElement>> *)activeApplications;
@end

@protocol RelayXCUIApplicationMonitor <NSObject>
- (XCUIApplication *)monitoredApplicationWithProcessIdentifier:(pid_t)processIdentifier;
@end

@protocol RelayXCUIDeviceAccessibility <NSObject>
- (id<RelayXCAXClient>)accessibilityInterface;
- (id<RelayXCUIApplicationMonitor>)applicationMonitor;
@end

@protocol RelayXCUIApplicationBundleID <NSObject>
- (NSString *)bundleID;
@end

static NSString *const RelayActiveApplicationErrorDomain = @"RelayActiveApplication";

@implementation RelayActiveApplicationInfo

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier processIdentifier:(pid_t)processIdentifier {
    if ((self = [super init])) {
        _bundleIdentifier = [bundleIdentifier copy];
        _processIdentifier = processIdentifier;
    }
    return self;
}

@end

@implementation RelayActiveApplication

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
    if ([NSProcessInfo.processInfo.environment[@"RELAY_DISABLE_PRIVATE_FOREGROUND"] isEqualToString:@"1"]) {
        return @"disabled by RELAY_DISABLE_PRIVATE_FOREGROUND=1";
    }
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![device respondsToSelector:@selector(accessibilityInterface)]) {
        return @"XCUIDevice does not respond to accessibilityInterface";
    }
    if (![device respondsToSelector:@selector(applicationMonitor)]) {
        return @"XCUIDevice does not respond to applicationMonitor";
    }
    id client = [(id<RelayXCUIDeviceAccessibility>)device accessibilityInterface];
    if (![client respondsToSelector:@selector(activeApplications)]) {
        return [NSString stringWithFormat:@"%@ does not respond to activeApplications", [client class]];
    }
    id monitor = [(id<RelayXCUIDeviceAccessibility>)device applicationMonitor];
    if (![monitor respondsToSelector:@selector(monitoredApplicationWithProcessIdentifier:)]) {
        return [NSString stringWithFormat:@"%@ does not respond to monitoredApplicationWithProcessIdentifier:", [monitor class]];
    }
    if (![XCUIApplication instancesRespondToSelector:@selector(bundleID)]) {
        return @"XCUIApplication does not respond to bundleID";
    }
    Class elementClass = NSClassFromString(@"XCAccessibilityElement");
    if (elementClass == Nil) {
        return @"XCAccessibilityElement not found";
    }
    if (![elementClass instancesRespondToSelector:@selector(processIdentifier)]) {
        return @"XCAccessibilityElement does not respond to processIdentifier";
    }
    return nil;
}

+ (nullable NSArray<RelayActiveApplicationInfo *> *)activeApplicationsWithError:(NSError **)error {
    NSString *reason = self.unavailableReason;
    NSMutableArray<RelayActiveApplicationInfo *> *applications = [NSMutableArray array];
    if (reason == nil) {
        id<RelayXCUIDeviceAccessibility> device = (id<RelayXCUIDeviceAccessibility>)XCUIDevice.sharedDevice;
        id<RelayXCUIApplicationMonitor> monitor = [device applicationMonitor];
        for (id<RelayXCAccessibilityElement> element in [[device accessibilityInterface] activeApplications]) {
            if (![element respondsToSelector:@selector(processIdentifier)]) {
                continue;
            }
            pid_t pid = [element processIdentifier];
            if (pid <= 0) {
                continue;
            }
            NSString *bundleID = [(id<RelayXCUIApplicationBundleID>)[monitor monitoredApplicationWithProcessIdentifier:pid] bundleID];
            if (bundleID.length == 0) {
                continue;
            }
            [applications addObject:[[RelayActiveApplicationInfo alloc] initWithBundleIdentifier:bundleID processIdentifier:pid]];
        }
        if (applications.count == 0) {
            reason = @"the accessibility client reported no active application";
        }
    }
    if (reason != nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:RelayActiveApplicationErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
    return applications;
}

@end
