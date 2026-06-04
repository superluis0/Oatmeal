#import "ExceptionCatcher.h"

@implementation ExceptionCatcher

+ (NSException *)catch:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    }
    @catch (NSException *exception) {
        return exception;
    }
}

@end
