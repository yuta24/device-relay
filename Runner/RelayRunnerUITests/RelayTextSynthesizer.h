#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Types text through XCTest's private event synthesizer, as `XCUIElement.typeText` does inside (and as
/// WebDriverAgent does).
///
/// Unlike `typeText`, this does not wait for the foreground app to become idle before and after the
/// text: an app whose main run loop never idles held `typeText` for 60 s on each side. It also does
/// not check keyboard focus; callers check it first. Every private class and selector is resolved at
/// runtime, so the runner still links and runs when they disappear; callers check `isAvailable` and
/// fall back to `typeText`.
@interface RelayTextSynthesizer : NSObject

/// YES when every private class and selector this path needs is present.
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Why the private path is unavailable, or nil when it is available.
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// Types `text` into whatever has keyboard focus, `typingSpeed` characters per second (XCTest's
/// `typeText` uses 60). Returns NO with `error` when nothing was sent. The completion may run on
/// any thread.
+ (BOOL)synthesizeText:(NSString *)text
           typingSpeed:(NSUInteger)typingSpeed
            completion:(void (^)(NSError *_Nullable error))completion
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
