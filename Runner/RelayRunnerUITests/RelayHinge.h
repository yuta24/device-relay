#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Simulator-only guest HID events. No host private API is used.
@interface RelayHinge : NSObject
+ (BOOL)hasHinge;
+ (nullable NSString *)unavailableReason;
+ (NSDictionary<NSString *, id> *)readAngle;
+ (NSDictionary<NSString *, id> *)setAngle:(double)degrees;
+ (NSDictionary<NSString *, id> *)setOrientation:(NSString *)value;
@end
NS_ASSUME_NONNULL_END
