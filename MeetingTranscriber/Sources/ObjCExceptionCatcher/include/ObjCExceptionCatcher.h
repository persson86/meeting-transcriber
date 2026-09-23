#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const MTObjCExceptionErrorDomain;
FOUNDATION_EXPORT NSString * const MTObjCExceptionNameKey;
FOUNDATION_EXPORT NSString * const MTObjCExceptionReasonKey;
FOUNDATION_EXPORT NSString * const MTObjCExceptionOperationKey;

/// Converte NSException em NSError. O @try/@catch fica inteiro em ObjC.
@interface MTObjCExceptionCatcher : NSObject

/// Executa `block` dentro de @try; uma NSException vira erro (retorno NO).
+ (BOOL)perform:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error;

/// Lança e captura uma NSException inteiramente em ObjC (para testar o shim
/// sem uma exceção atravessar frames Swift).
+ (BOOL)raiseTestExceptionWithReason:(NSString *)reason error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
