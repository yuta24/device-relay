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

/// YES when the event record can be aimed at one display (`-initWithName:displayID:interfaceOrientation:`,
/// Xcode 27.1 and later). Without it, events go to the main display.
@property (class, nonatomic, readonly) BOOL supportsDisplayID;

/// A single-finger touch: down at `points[0]` (offset 0), then a move to each following point at
/// the matching entry of `offsets` (seconds from touch down), then lift up at `liftOffset`.
/// `points` are screen points from the top-left corner of the native portrait screen; the synthesizer
/// does not rotate them by `orientation`, so callers convert landscape points first.
/// `displayID` (an `XCUIScreen` display ID) sends the touch to that display, in its own points; nil sends
/// it to the main display. A display ID without `supportsDisplayID` is an error rather than a touch that
/// silently lands on the main display. The completion may run on any thread.
+ (BOOL)synthesizeTouchWithPoints:(NSArray<NSValue *> *)points
                          offsets:(NSArray<NSNumber *> *)offsets
                       liftOffset:(NSTimeInterval)liftOffset
             interfaceOrientation:(UIInterfaceOrientation)orientation
                        displayID:(nullable NSNumber *)displayID
                       completion:(void (^)(NSError *_Nullable error))completion
                            error:(NSError **)error;

/// `count` taps at `point` in one event record, as one gesture: finger `i` goes down at `i * period` seconds
/// and lifts `duration` later. Points, `orientation`, `displayID`, and the completion are as above.
+ (BOOL)synthesizeTapsAtPoint:(CGPoint)point
                        count:(NSUInteger)count
                     duration:(NSTimeInterval)duration
                       period:(NSTimeInterval)period
         interfaceOrientation:(UIInterfaceOrientation)orientation
                    displayID:(nullable NSNumber *)displayID
                   completion:(void (^)(NSError *_Nullable error))completion
                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
