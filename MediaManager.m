#import "MediaManager.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <string.h>

@interface MediaManager ()
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) int64_t frameIndex;
@end

@implementation MediaManager

+ (instancetype)sharedManager {
    static MediaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MediaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = VCamModeBlack;
        _loopPlayback = YES;
        _isRunning = NO;
        _videoSize = CGSizeMake(1920, 1080);
        _decodeQueue = dispatch_queue_create("com.vcam.decode", DISPATCH_QUEUE_SERIAL);
        _startTime = kCMTimeZero;
        _frameIndex = 0;
    }
    return self;
}

#pragma mark - Media Loading

- (void)loadMediaFromURL:(NSURL *)url {
    if (!url) {
        NSLog(@"[VCam] Error: URL de vídeo inválida");
        return;
    }

    dispatch_async(_decodeQueue, ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];

        NSArray<AVAssetTrack *> *tracks =
            [asset tracksWithMediaType:AVMediaTypeVideo];

        if (tracks.count == 0) {
            NSLog(@"[VCam] Error: el archivo no contiene vídeo");
            return;
        }

        AVAssetTrack *track = tracks.firstObject;

        CGSize size = CGSizeApplyAffineTransform(
            track.naturalSize,
            track.preferredTransform
        );

        size.width = fabs(size.width);
        size.height = fabs(size.height);

        if (size.width <= 0 || size.height <= 0) {
            NSLog(@"[VCam] Error: dimensiones de vídeo inválidas");
            return;
        }

        self.currentAsset = asset;
        self.videoDuration = asset.duration;
        self.videoSize = size;

        [self resetReaders];

        if (!self.videoReader ||
            self.videoReader.status != AVAssetReaderStatusReading) {
            NSLog(@"[VCam] Error al iniciar el lector de vídeo: %@",
                  self.videoReader.error);
            return;
        }

        self.mode = VCamModeVideo;
        NSLog(@"[VCam] Vídeo cargado correctamente");
    });
}

- (void)resetReaders {
    if (!self.currentAsset) {
        NSLog(@"[VCam] Error: no hay ningún vídeo cargado");
        return;
    }

    // Liberar las referencias a los lectores anteriores.
    self.videoOutput = nil;
    self.audioOutput = nil;
    self.videoReader = nil;
    self.audioReader = nil;

    NSError *error = nil;

    // Preparar el lector de vídeo.
    self.videoReader =
        [AVAssetReader assetReaderWithAsset:self.currentAsset error:&error];

    if (!self.videoReader) {
        NSLog(@"[VCam] No se pudo crear el lector de vídeo: %@",
              error.localizedDescription);
        return;
    }

    NSArray<AVAssetTrack *> *videoTracks =
        [self.currentAsset tracksWithMediaType:AVMediaTypeVideo];

    if (videoTracks.count == 0) {
        NSLog(@"[VCam] El archivo no contiene una pista de vídeo");
        self.videoReader = nil;
        return;
    }

    NSDictionary *videoSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };

    self.videoOutput =
        [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:videoTracks.firstObject
                             outputSettings:videoSettings];

    self.videoOutput.alwaysCopiesSampleData = NO;

    if (![self.videoReader canAddOutput:self.videoOutput]) {
        NSLog(@"[VCam] No se pudo añadir la salida de vídeo");
        self.videoOutput = nil;
        self.videoReader = nil;
        return;
    }

    [self.videoReader addOutput:self.videoOutput];

    if (![self.videoReader startReading]) {
        NSLog(@"[VCam] No se pudo iniciar el lector de vídeo: %@",
              self.videoReader.error.localizedDescription);
        self.videoOutput = nil;
        self.videoReader = nil;
        return;
    }

    // Preparar el lector de audio, si el vídeo tiene audio.
    NSArray<AVAssetTrack *> *audioTracks =
        [self.currentAsset tracksWithMediaType:AVMediaTypeAudio];

    if (audioTracks.count == 0) {
        NSLog(@"[VCam] El vídeo no contiene audio");
        return;
    }

    error = nil;
    self.audioReader =
        [AVAssetReader assetReaderWithAsset:self.currentAsset error:&error];

    if (!self.audioReader) {
        NSLog(@"[VCam] No se pudo crear el lector de audio: %@",
              error.localizedDescription);
        return;
    }

    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @44100,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO
    };

    self.audioOutput =
        [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:audioTracks.firstObject
                             outputSettings:audioSettings];

    self.audioOutput.alwaysCopiesSampleData = NO;

    if (![self.audioReader canAddOutput:self.audioOutput]) {
        NSLog(@"[VCam] No se pudo añadir la salida de audio");
        self.audioOutput = nil;
        self.audioReader = nil;
        return;
    }

    [self.audioReader addOutput:self.audioOutput];

    if (![self.audioReader startReading]) {
        NSLog(@"[VCam] No se pudo iniciar el lector de audio: %@",
              self.audioReader.error.localizedDescription);
        self.audioOutput = nil;
        self.audioReader = nil;
        return;
    }

    NSLog(@"[VCam] Lectores de vídeo y audio preparados");
}

#pragma mark - Frame Generation

- (CMSampleBufferRef)nextVideoFrame {
    if (self.mode != VCamModeVideo || !self.videoOutput) {
        CMTime pts = CMTimeMakeWithSeconds(
            CACurrentMediaTime(), 1000000
        );

        return [self generateBlackFrameWithSize:self.videoSize
                               presentationTime:pts];
    }

    CMSampleBufferRef sample =
        [self.videoOutput copyNextSampleBuffer];

    // Si terminó el vídeo, intentar reiniciar los lectores.
    if (!sample) {
        AVAssetReaderStatus status = self.videoReader.status;

        if (status == AVAssetReaderStatusFailed) {
            NSLog(@"[VCam] Error leyendo vídeo: %@",
                  self.videoReader.error.localizedDescription);
        }

        if (self.loopPlayback &&
            self.currentAsset &&
            (status == AVAssetReaderStatusCompleted ||
             status == AVAssetReaderStatusFailed)) {

            [self resetReaders];

            if (self.videoReader.status == AVAssetReaderStatusReading &&
                self.videoOutput) {
                sample = [self.videoOutput copyNextSampleBuffer];
            }
        }

        // Si no se pudo obtener un fotograma, generar negro.
        if (!sample) {
            CMTime pts = CMTimeMakeWithSeconds(
                CACurrentMediaTime(), 1000000
            );

            return [self generateBlackFrameWithSize:self.videoSize
                                   presentationTime:pts];
        }
    }

    // Crear una copia para cambiar su tiempo de presentación.
    CMTime now = CMTimeMakeWithSeconds(
        CACurrentMediaTime(), 1000000
    );

    CMSampleBufferRef copy = NULL;
    OSStatus result =
        CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &copy);

    CFRelease(sample);

    if (result != noErr || !copy) {
        NSLog(@"[VCam] No se pudo copiar el fotograma: %d",
              (int)result);
        return NULL;
    }

    result = CMSampleBufferSetOutputPresentationTimeStamp(copy, now);

    if (result != noErr) {
        NSLog(@"[VCam] No se pudo actualizar el tiempo del fotograma: %d",
              (int)result);
        CFRelease(copy);
        return NULL;
    }

    return copy;
}

- (CMSampleBufferRef)nextAudioFrame {
    if (!self.audioOutput) return NULL;
    
    CMSampleBufferRef sample = [self.audioOutput copyNextSampleBuffer];
    if (!sample && self.loopPlayback) {
        // Audio reader reset handled separately if needed
        return NULL;
    }
    return sample;
}

#pragma mark - Black Frame

- (CMSampleBufferRef)generateBlackFrameWithSize:(CGSize)size presentationTime:(CMTime)pts {
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)size.width,
                                          (size_t)size.height,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                          (__bridge CFDictionaryRef)attrs,
                                          &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;
    
    // Fill with black (zero all planes)
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    void *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    memset(yPlane, 16, yBytesPerRow * yHeight);  // Y=16 for black in limited range, 0 for full
    
    void *uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    memset(uvPlane, 128, uvBytesPerRow * uvHeight);  // UV=128 for neutral chroma
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // Create CMVideoFormatDescription
    CMVideoFormatDescriptionRef formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    
    // Create CMSampleBuffer
    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = pts,
    };
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                       pixelBuffer,
                                       YES,
                                       NULL, NULL,
                                       formatDesc,
                                       &timing,
                                       &sampleBuffer);
    
    if (formatDesc) CFRelease(formatDesc);
    CVPixelBufferRelease(pixelBuffer);
    
    return sampleBuffer;
}

#pragma mark - Lifecycle

- (void)start {
    self.isRunning = YES;
    self.startTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
}

- (void)stop {
    self.isRunning = NO;
}

@end
