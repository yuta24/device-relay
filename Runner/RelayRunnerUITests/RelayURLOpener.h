#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Opens a URL through XCTest's private daemon session, as `XCUIDevice.system.open(_:)` and
/// `XCUIApplication.open(_:)` do inside (and as WebDriverAgent does).
///
/// Unlike those, this does not wait for the foreground app (or the app opening the URL) to become idle:
/// an app whose main run loop never idles held them for 60 s or more. Callers wait for the app to come
/// to the foreground themselves. Every private class and selector is resolved at runtime, so the runner
/// still links and runs when they disappear; callers check `isAvailable` and fall back to the public API.
@interface RelayURLOpener : NSObject

/// YES when every private class and selector this path needs is present.
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Why the private path is unavailable, or nil when it is available.
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// Opens `url` with the app the system picks for it, or with `bundleID` when it is not nil. The
/// completion gets nil when the system accepted the URL, and may run on any thread.
+ (void)openURL:(NSURL *)url
       bundleID:(nullable NSString *)bundleID
     completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
