#import "ObjCExceptionCatcher.h"

NSErrorDomain const MTObjCExceptionErrorDomain = @"MeetingTranscriber.ObjCException";
NSString * const MTObjCExceptionNameKey = @"MTObjCExceptionName";
NSString * const MTObjCExceptionReasonKey = @"MTObjCExceptionReason";
NSString * const MTObjCExceptionOperationKey = @"MTObjCExceptionOperation";

static NSError *MTErrorFromException(NSException *exception, NSString *operation) {
    NSString *name = exception.name ?: @"NSException";
    NSString *reason = exception.reason ?: @"";
    NSString *description = [NSString stringWithFormat:@"%@: %@ — %@", operation, name, reason];
    return [NSError errorWithDomain:MTObjCExceptionErrorDomain
                               code:1
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
        MTObjCExceptionNameKey: name,
        MTObjCExceptionReasonKey: reason,
        MTObjCExceptionOperationKey: operation,
    }];
}

static void MTSetError(NSError **error, NSError *value) {
    if (error != NULL) {
        *error = value;
    }
}

@implementation MTObjCExceptionCatcher

+ (BOOL)perform:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"perform"));
        return NO;
    }
}

+ (BOOL)raiseTestExceptionWithReason:(NSString *)reason error:(NSError **)error {
    @try {
        @throw [NSException exceptionWithName:@"MTTestException" reason:reason userInfo:nil];
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"raiseTestException"));
        return NO;
    }
}

@end
