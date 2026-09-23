#import "ObjCExceptionCatcher.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

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

@implementation MTAudioEngineShim

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = [[AVAudioEngine alloc] init];
    }
    return self;
}

#if !__has_feature(objc_arc)
- (void)dealloc {
    [_engine release];
    [super dealloc];
}
#endif

- (BOOL)isRunning {
    @try {
        return _engine.isRunning;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (AVAudioFormat *)inputFormatAndReturnError:(NSError **)error {
    @try {
        return [_engine.inputNode outputFormatForBus:0];
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"inputFormat"));
        return nil;
    }
}

- (BOOL)installInputTapWithBufferSize:(AVAudioFrameCount)bufferSize
                                block:(AVAudioNodeTapBlock)block
                                error:(NSError **)error {
    @try {
        [_engine.inputNode installTapOnBus:0 bufferSize:bufferSize format:nil block:block];
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"installTap"));
        return NO;
    }
}

- (BOOL)removeInputTapAndReturnError:(NSError **)error {
    @try {
        [_engine.inputNode removeTapOnBus:0];
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"removeTap"));
        return NO;
    }
}

- (BOOL)prepareAndReturnError:(NSError **)error {
    @try {
        [_engine prepare];
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"prepare"));
        return NO;
    }
}

- (BOOL)startAndReturnError:(NSError **)error {
    @try {
        NSError *startError = nil;
        if ([_engine startAndReturnError:&startError]) {
            return YES;
        }
        if (startError == nil) {
            startError = [NSError errorWithDomain:MTObjCExceptionErrorDomain
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"AVAudioEngine não iniciou e não informou o erro."}];
        }
        MTSetError(error, startError);
        return NO;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"start"));
        return NO;
    }
}

- (BOOL)stopAndReturnError:(NSError **)error {
    @try {
        [_engine stop];
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"stop"));
        return NO;
    }
}

// MARK: - Dispositivo de entrada (CoreAudio, barato, sem tocar no default do sistema)

- (AudioDeviceID)currentInputDeviceID {
    @try {
        AudioUnit unit = _engine.inputNode.audioUnit;
        if (unit == NULL) {
            return kAudioObjectUnknown;
        }
        AudioDeviceID deviceID = kAudioObjectUnknown;
        UInt32 size = sizeof(deviceID);
        OSStatus status = AudioUnitGetProperty(unit,
                                               kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global,
                                               0,
                                               &deviceID,
                                               &size);
        return status == noErr ? deviceID : kAudioObjectUnknown;
    } @catch (NSException *exception) {
        return kAudioObjectUnknown;
    }
}

static NSString *MTDeviceStringProperty(AudioDeviceID deviceID, AudioObjectPropertySelector selector) {
    if (deviceID == kAudioObjectUnknown) {
        return nil;
    }
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

- (NSString *)inputDeviceUID {
    return MTDeviceStringProperty([self currentInputDeviceID], kAudioDevicePropertyDeviceUID);
}

- (NSString *)inputDeviceName {
    return MTDeviceStringProperty([self currentInputDeviceID], kAudioObjectPropertyName);
}

- (NSString *)inputDeviceTransport {
    AudioDeviceID deviceID = [self currentInputDeviceID];
    if (deviceID == kAudioObjectUnknown) {
        return nil;
    }
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 transport = 0;
    UInt32 size = sizeof(transport);
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &transport) != noErr) {
        return nil;
    }
    switch (transport) {
        case kAudioDeviceTransportTypeBuiltIn: return @"built-in";
        case kAudioDeviceTransportTypeUSB: return @"usb";
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: return @"bluetooth";
        case kAudioDeviceTransportTypeVirtual: return @"virtual";
        case kAudioDeviceTransportTypeAggregate: return @"aggregate";
        case kAudioDeviceTransportTypeHDMI: return @"hdmi";
        case kAudioDeviceTransportTypeDisplayPort: return @"displayport";
        case kAudioDeviceTransportTypeThunderbolt: return @"thunderbolt";
        case kAudioDeviceTransportTypeAirPlay: return @"airplay";
        default: return [NSString stringWithFormat:@"0x%08X", (unsigned int)transport];
    }
}

@end

@implementation MTCaptureSessionShim

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = [[AVCaptureSession alloc] init];
    }
    return self;
}

#if !__has_feature(objc_arc)
- (void)dealloc {
    [_session release];
    [super dealloc];
}
#endif

- (BOOL)isRunning {
    @try {
        return _session.isRunning;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)configureWithDevice:(AVCaptureDevice *)device
                     output:(AVCaptureOutput *)output
                      error:(NSError **)error {
    @try {
        NSError *inputError = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
        if (input == nil) {
            MTSetError(error, inputError ?: [NSError errorWithDomain:MTObjCExceptionErrorDomain
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"AVCaptureDeviceInput não pôde ser criado para o microfone."}]);
            return NO;
        }
        [_session beginConfiguration];
        BOOL accepted = [_session canAddInput:input] && [_session canAddOutput:output];
        if (accepted) {
            [_session addInput:input];
            [_session addOutput:output];
        }
        [_session commitConfiguration];
        if (!accepted) {
            MTSetError(error, [NSError errorWithDomain:MTObjCExceptionErrorDomain
                                                  code:4
                                              userInfo:@{NSLocalizedDescriptionKey: @"AVCaptureSession recusou a entrada ou a saída de áudio."}]);
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"configureCaptureSession"));
        return NO;
    }
}

- (BOOL)startRunningAndReturnError:(NSError **)error {
    @try {
        [_session startRunning];
        if (!_session.isRunning) {
            MTSetError(error, [NSError errorWithDomain:MTObjCExceptionErrorDomain
                                                  code:5
                                              userInfo:@{NSLocalizedDescriptionKey: @"AVCaptureSession não entrou em execução."}]);
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"startCaptureSession"));
        return NO;
    }
}

- (BOOL)stopRunningAndReturnError:(NSError **)error {
    @try {
        [_session stopRunning];
        return YES;
    } @catch (NSException *exception) {
        MTSetError(error, MTErrorFromException(exception, @"stopCaptureSession"));
        return NO;
    }
}

@end
