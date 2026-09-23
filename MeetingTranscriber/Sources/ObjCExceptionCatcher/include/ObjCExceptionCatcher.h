#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

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

/// Dono do AVAudioEngine. Toda chamada que pode levantar NSException
/// (inputNode, formato, tap, prepare, start, stop) roda aqui, em ObjC.
@interface MTAudioEngineShim : NSObject

@property (nonatomic, readonly) AVAudioEngine *engine;
@property (nonatomic, readonly) BOOL isRunning;

/// Dispositivo de entrada do IO unit do inputNode (CoreAudio); nil se indisponível.
@property (nonatomic, readonly, nullable) NSString *inputDeviceUID;
@property (nonatomic, readonly, nullable) NSString *inputDeviceName;
@property (nonatomic, readonly, nullable) NSString *inputDeviceTransport;

- (nullable AVAudioFormat *)inputFormatAndReturnError:(NSError **)error;

/// Tap com `format: nil`: o formato real chega em cada buffer.
- (BOOL)installInputTapWithBufferSize:(AVAudioFrameCount)bufferSize
                                block:(AVAudioNodeTapBlock)block
                                error:(NSError **)error;
- (BOOL)removeInputTapAndReturnError:(NSError **)error;
- (BOOL)prepareAndReturnError:(NSError **)error;
- (BOOL)startAndReturnError:(NSError **)error;
- (BOOL)stopAndReturnError:(NSError **)error;

@end

/// Dono do AVCaptureSession do fallback: configuração, start e stop rodam em ObjC
/// para que uma NSException vire NSError.
@interface MTCaptureSessionShim : NSObject

@property (nonatomic, readonly) AVCaptureSession *session;
@property (nonatomic, readonly) BOOL isRunning;

- (BOOL)configureWithDevice:(AVCaptureDevice *)device
                     output:(AVCaptureOutput *)output
                      error:(NSError **)error;
- (BOOL)startRunningAndReturnError:(NSError **)error;
- (BOOL)stopRunningAndReturnError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
