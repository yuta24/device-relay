#import "RelayActiveApplication.h"

#import <XCTest/XCTest.h>

// Private XCTest interfaces (XCUIAutomation.framework and XCTAutomationSupport.framework in Xcode 27).
// Declared as protocols so the runner never links against the private class symbols.

@protocol RelayXCAccessibilityElement <NSObject>
- (pid_t)processIdentifier;
@end

@protocol RelayHitSnapshot <NSObject>
- (id)accessibilityElement;
- (NSArray<id<RelayHitSnapshot>> *)children;
@end

@protocol RelayXCAXClient <NSObject>
- (id)hitTestElement:(id)element withPoint:(CGPoint)point error:(NSError **)error;
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

+ (nullable NSArray<NSNumber *> *)pathOfElement:(id)element inSnapshot:(id<RelayHitSnapshot>)snapshot {
    if (![snapshot respondsToSelector:@selector(accessibilityElement)] ||
        ![snapshot respondsToSelector:@selector(children)]) {
        return nil;
    }
    if ([[snapshot accessibilityElement] isEqual:element]) {
        return @[];
    }
    NSUInteger index = 0;
    for (id<RelayHitSnapshot> child in [snapshot children]) {
        NSArray<NSNumber *> *suffix = [self pathOfElement:element inSnapshot:child];
        if (suffix != nil) {
            return [@[@(index)] arrayByAddingObjectsFromArray:suffix];
        }
        index++;
    }
    return nil;
}

+ (nullable NSArray<NSNumber *> *)hitPathAtPoint:(CGPoint)point snapshot:(id)snapshot {
    if ([NSProcessInfo.processInfo.environment[@"RELAY_DISABLE_PRIVATE_HITTEST"] isEqualToString:@"1"]) {
        return nil;
    }
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![device respondsToSelector:@selector(accessibilityInterface)]) {
        return nil;
    }
    id<RelayXCAXClient> client = [(id<RelayXCUIDeviceAccessibility>)device accessibilityInterface];
    if (![client respondsToSelector:@selector(hitTestElement:withPoint:error:)] ||
        ![snapshot respondsToSelector:@selector(accessibilityElement)]) {
        return nil;
    }
    id applicationElement = [(id<RelayHitSnapshot>)snapshot accessibilityElement];
    if (applicationElement == nil) {
        return nil;
    }
    NSError *error = nil;
    id hit = [client hitTestElement:applicationElement withPoint:point error:&error];
    if (hit == nil || error != nil) {
        return nil;
    }
    return [self pathOfElement:hit inSnapshot:snapshot];
}

@end
