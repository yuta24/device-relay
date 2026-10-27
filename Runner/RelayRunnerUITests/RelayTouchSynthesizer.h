#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Synthesizes touches through XCTest's private event synthesizer (the WebDriverAgent approach).
///
/// Unlike `XCUICoordinate`, this does not wait for the foreground app to become idle before and
/// after the event. Every private class and selector is resolved at runtime, so the runner still
/// links and runs when they disappear; callers check `isAvailable` and fall back to public XCUI.
@interface RelayTouchSynthesizer : NSObject

/// YES when every private class and selector this path needs is present.
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Why the private path is unavailable, or nil when it is available.
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// A single-finger touch: down at `points[0]` (offset 0), then a move to each following point at
/// the matching entry of `offsets` (seconds from touch down), then lift up at `liftOffset`.
/// `points` are screen points from the top-left corner in the given interface orientation.
/// The completion may run on any thread.
+ (BOOL)synthesizeTouchWithPoints:(NSArray<NSValue *> *)points
                          offsets:(NSArray<NSNumber *> *)offsets
                       liftOffset:(NSTimeInterval)liftOffset
             interfaceOrientation:(UIInterfaceOrientation)orientation
                       completion:(void (^)(NSError *_Nullable error))completion
                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
