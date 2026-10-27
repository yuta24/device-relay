#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One application that XCTest's accessibility client reports as active (the WebDriverAgent
/// `fb_activeApplication` approach).
@interface RelayActiveApplicationInfo : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) pid_t processIdentifier;
@end

/// Finds the active (foreground) applications through XCTest's private accessibility client.
///
/// Every private class and selector is resolved at runtime, so the runner still links and runs when
/// they disappear; callers check `isAvailable` and fall back to what they already know.
@interface RelayActiveApplication : NSObject

/// YES when every private class and selector this path needs is present.
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Why the private path is unavailable, or nil when it is available.
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// The active applications in the order the accessibility client reports them, or nil with `error`
/// set when the private path is unavailable or no application could be resolved to a bundle ID.
+ (nullable NSArray<RelayActiveApplicationInfo *> *)activeApplicationsWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
