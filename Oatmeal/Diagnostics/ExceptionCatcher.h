#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C exception handling to Swift. CoreData/SwiftData can throw
/// NSExceptions (e.g. a faulted row that no longer exists) which Swift's `try?`
/// cannot catch — they abort the process. Wrapping the risky call in this lets us
/// recover instead of crashing.
@interface ExceptionCatcher : NSObject

/// Runs `block`, returning the caught NSException (or nil on success).
+ (nullable NSException *)catch:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
