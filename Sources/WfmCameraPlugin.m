#import "WfmCameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

@interface WfmCameraPlugin () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureDeviceInput *backInput;
@property (nonatomic, strong) AVCaptureDeviceInput *frontInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *backOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontOutput;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) UIView *frontPreviewView;
@property (nonatomic, strong) UIImageView *backImageView;
@property (nonatomic, strong) UIImageView *frontImageView;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, strong) NSMutableArray *logs;
@property (nonatomic, strong) UniModuleKeepAliveCallback currentCallback;

// UI 控件
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *captureButton;

// 拍照相关
@property (nonatomic, strong) UIImage *backImage;
@property (nonatomic, strong) UIImage *frontImage;
@property (nonatomic, assign) BOOL waitingForBackPhoto;
@property (nonatomic, assign) BOOL waitingForFrontPhoto;
@property (nonatomic, assign) BOOL isTakingPhoto;

@end

@implementation WfmCameraPlugin

UNI_EXPORT_METHOD(@selector(test:callback:))
UNI_EXPORT_METHOD(@selector(openDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(closeDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(log:callback:))

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoQueue = dispatch_queue_create("com.wfm.camera.queue", DISPATCH_QUEUE_SERIAL);
        _logs = [NSMutableArray array];
    }
    return self;
}

- (void)addLog:(NSString *)message {
    if (!self.logs) {
        self.logs = [NSMutableArray array];
    }
    [self.logs addObject:message];
    NSLog(@"[WfmCameraPlugin] %@", message);
}

- (void)sendResult:(BOOL)success message:(NSString *)message callback:(UniModuleKeepAliveCallback)callback {
    if (callback) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"success"] = @(success);
        if (message) {
            result[@"msg"] = message;
        }
        if (self.logs && self.logs.count > 0) {
            result[@"logs"] = [self.logs copy];
        }
        callback(result, NO);
    }
    if (self.logs) {
        [self.logs removeAllObjects];
    }
    self.currentCallback = nil;
}

- (void)sendPhotoResult:(NSString *)backPath frontPath:(NSString *)frontPath {
    if (self.currentCallback) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"success"] = @YES;
        result[@"msg"] = @"拍照成功";
        if (backPath) {
            result[@"backPath"] = backPath;
        }
        if (frontPath) {
            result[@"frontPath"] = frontPath;
        }
        if (self.logs && self.logs.count > 0) {
            result[@"logs"] = [self.logs copy];
        }
        self.currentCallback(result, NO);
        self.currentCallback = nil;
    }
    [self.logs removeAllObjects];
}

- (void)saveImageToPhotoLibrary:(UIImage *)image completion:(void(^)(NSString *path, NSError *error))completion {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
            if (newStatus == PHAuthorizationStatusAuthorized) {
                [self performSaveImage:image completion:completion];
            } else {
                if (completion) {
                    completion(nil, [NSError errorWithDomain:@"WfmCameraPlugin" code:4001 userInfo:@{NSLocalizedDescriptionKey: @"相册权限未授权"}]);
                }
            }
        }];
    } else if (status == PHAuthorizationStatusAuthorized) {
        [self performSaveImage:image completion:completion];
    } else {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"WfmCameraPlugin" code:4002 userInfo:@{NSLocalizedDescriptionKey: @"请先在设置中开启相册权限"}]);
        }
    }
}

- (void)performSaveImage:(UIImage *)image completion:(void(^)(NSString *path, NSError *error))completion {
    __block NSString *localIdentifier = nil;
    
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        localIdentifier = request.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        if (success && localIdentifier) {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *documentsPath = paths.firstObject;
            NSString *fileName = [NSString stringWithFormat:@"photo_%.0f.jpg", [[NSDate date] timeIntervalSince1970]];
            NSString *filePath = [documentsPath stringByAppendingPathComponent:fileName];
            
            NSData *imageData = UIImageJPEGRepresentation(image, 0.9);
            [imageData writeToFile:filePath atomically:YES];
            
            if (completion) {
                completion(filePath, nil);
            }
        } else {
            if (completion) {
                completion(nil, error ?: [NSError errorWithDomain:@"WfmCameraPlugin" code:4004 userInfo:@{NSLocalizedDescriptionKey: @"保存图片失败"}]);
            }
        }
    }];
}

- (void)log:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *message = options[@"message"] ?: @"";
    [self addLog:message];
    if (callback) {
        callback(@{@"success": @YES, @"log": message}, NO);
    }
}

- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    [self addLog:@"========== test 方法开始 =========="];
    [self addLog:@"测试第一条日志"];
    [self addLog:@"测试第二条日志"];
    [self addLog:@"测试第三条日志"];
    [self addLog:@"========== test 方法结束 =========="];
    [self sendResult:YES message:@"插件工作正常！" callback:callback];
}

- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    self.currentCallback = callback;
    self.isTakingPhoto = NO;
    
    [self addLog:@"========== 打开双摄 =========="];
    
    @try {
        if (@available(iOS 13.0, *)) {
            [self addLog:@"✅ iOS 13+ 检查通过"];
        } else {
            [self addLog:@"❌ 需要 iOS 13 或更高版本"];
            [self sendResult:NO message:@"需要 iOS 13 或更高版本" callback:callback];
            return;
        }
        
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        [self addLog:[NSString stringWithFormat:@"相机权限状态: %ld", (long)status]];
        
        if (status != AVAuthorizationStatusAuthorized) {
            if (status == AVAuthorizationStatusNotDetermined) {
                [self addLog:@"请求相机权限..."];
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) {
                            [self addLog:@"✅ 权限已授权"];
                            [self setupDualCamera];
                        } else {
                            [self addLog:@"❌ 用户拒绝相机权限"];
                            [self sendResult:NO message:@"需要相机权限" callback:callback];
                        }
                    });
                }];
            } else {
                [self addLog:@"❌ 相机权限未授权"];
                [self sendResult:NO message:@"请先在设置中开启相机权限" callback:callback];
            }
            return;
        }
        
        [self addLog:@"✅ 相机权限已授权"];
        [self setupDualCamera];
        
    } @catch (NSException *exception) {
        [self addLog:[NSString stringWithFormat:@"❌ 异常: %@", exception.reason]];
        [self sendResult:NO message:exception.reason callback:callback];
    }
}

- (void)setupDualCamera API_AVAILABLE(ios(13.0)) {
    [self addLog:@"开始设置双摄..."];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 创建多摄会话
            self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
            
            // 获取后置摄像头
            AVCaptureDevice *backCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                              mediaType:AVMediaTypeVideo
                                                                               position:AVCaptureDevicePositionBack];
            if (!backCamera) {
                [self addLog:@"❌ 找不到后置摄像头"];
                [self sendResult:NO message:@"找不到后置摄像头" callback:self.currentCallback];
                return;
            }
            
            // ✅ 关键修复：设置后置摄像头格式为高分辨率宽屏
            [self addLog:@"设置后置摄像头格式..."];
            NSError *lockError = nil;
            if ([backCamera lockForConfiguration:&lockError]) {
                NSArray *formats = backCamera.formats;
                AVCaptureDeviceFormat *selectedFormat = nil;
                
                // 优先选择 1920x1080 (16:9) 或更高分辨率
                for (AVCaptureDeviceFormat *format in formats) {
                    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                    if (dimensions.width >= 1920 && dimensions.height >= 1080) {
                        selectedFormat = format;
                        break;
                    }
                }
                
                // 如果没有找到 16:9，选择最高分辨率
                if (!selectedFormat && formats.count > 0) {
                    selectedFormat = formats.lastObject;
                }
                
                if (selectedFormat) {
                    backCamera.activeFormat = selectedFormat;
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription);
                    [self addLog:[NSString stringWithFormat:@"✅ 后置摄像头格式: %dx%d", dims.width, dims.height]];
                }
                [backCamera unlockForConfiguration];
            }
            
            // 获取前置摄像头
            AVCaptureDevice *frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                               mediaType:AVMediaTypeVideo
                                                                                position:AVCaptureDevicePositionFront];
            if (!frontCamera) {
                [self addLog:@"❌ 找不到前置摄像头"];
                [self sendResult:NO message:@"找不到前置摄像头" callback:self.currentCallback];
                return;
            }
            
            // 添加后置输入
            NSError *error = nil;
            self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&error];
            if (error || ![self.multiCamSession canAddInput:self.backInput]) {
                [self addLog:@"❌ 无法添加后置输入"];
                [self sendResult:NO message:@"后置摄像头添加失败" callback:self.currentCallback];
                return;
            }
            [self.multiCamSession addInput:self.backInput];
            
            // 添加前置输入
            self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
            if (error || ![self.multiCamSession canAddInput:self.frontInput]) {
                [self addLog:@"❌ 无法添加前置输入"];
                [self sendResult:NO message:@"前置摄像头添加失败" callback:self.currentCallback];
                return;
            }
            [self.multiCamSession addInput:self.frontInput];
            
            // 步骤6: 添加后置视频输出
            [self addLog:@"步骤6: 添加后置视频输出..."];
            self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.backOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.backOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.backOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.backOutput];
                
                if (self.backInput.ports.count > 0) {
                    AVCaptureConnection *backConnection = [AVCaptureConnection connectionWithInputPorts:self.backInput.ports output:self.backOutput];
                    if (backConnection) {
                        // 启用视频防抖
                        if (backConnection.isVideoStabilizationSupported) {
                            backConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
                        }
                        if ([self.multiCamSession canAddConnection:backConnection]) {
                            [self.multiCamSession addConnection:backConnection];
                            [self addLog:@"步骤6: ✅ 后置视频输出添加成功"];
                        }
                    }
                }
            }
            
            // 步骤7: 添加前置视频输出
            [self addLog:@"步骤7: 添加前置视频输出..."];
            self.frontOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.frontOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.frontOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.frontOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.frontOutput];
                
                if (self.frontInput.ports.count > 0) {
                    AVCaptureConnection *frontConnection = [AVCaptureConnection connectionWithInputPorts:self.frontInput.ports output:self.frontOutput];
                    if (frontConnection) {
                        if (frontConnection.isVideoMirroringSupported) {
                            frontConnection.videoMirrored = YES;
                        }
                        if ([self.multiCamSession canAddConnection:frontConnection]) {
                            [self.multiCamSession addConnection:frontConnection];
                            [self addLog:@"步骤7: ✅ 前置视频输出添加成功"];
                        }
                    }
                }
            }
            
            // 获取当前视图
            UIViewController *topVC = [self getTopViewController];
            if (!topVC) {
                [self addLog:@"❌ 无法获取当前视图"];
                [self sendResult:NO message:@"无法获取当前视图" callback:self.currentCallback];
                return;
            }
            
            // 创建后置预览视图 - 全屏填充
            self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
            self.backPreviewView.backgroundColor = [UIColor blackColor];
            [topVC.view addSubview:self.backPreviewView];
            
            self.backImageView = [[UIImageView alloc] initWithFrame:self.backPreviewView.bounds];
            // 使用 ScaleAspectFill 让画面填满全屏
            self.backImageView.contentMode = UIViewContentModeScaleAspectFill;
            self.backImageView.backgroundColor = [UIColor blackColor];
            self.backImageView.transform = CGAffineTransformMakeRotation(M_PI_2);
            [self.backPreviewView addSubview:self.backImageView];
            
            // 创建前置预览小窗
            CGFloat smallWidth = 120;
            CGFloat smallHeight = 160;
            CGFloat margin = 16;
            CGFloat topOffset = 100;
            
            self.frontPreviewView = [[UIView alloc] initWithFrame:CGRectMake(
                topVC.view.bounds.size.width - smallWidth - margin,
                topOffset,
                smallWidth,
                smallHeight
            )];
            self.frontPreviewView.backgroundColor = [UIColor blackColor];
            self.frontPreviewView.layer.cornerRadius = 8;
            self.frontPreviewView.layer.masksToBounds = YES;
            self.frontPreviewView.layer.borderWidth = 2;
            self.frontPreviewView.layer.borderColor = [UIColor whiteColor].CGColor;
            [topVC.view addSubview:self.frontPreviewView];
            
            self.frontImageView = [[UIImageView alloc] initWithFrame:self.frontPreviewView.bounds];
            self.frontImageView.contentMode = UIViewContentModeScaleAspectFill;
            self.frontImageView.transform = CGAffineTransformMakeRotation(M_PI_2);
            self.frontImageView.transform = CGAffineTransformScale(self.frontImageView.transform, -1, 1);
            [self.frontPreviewView addSubview:self.frontImageView];
            
            // 创建返回按钮
            self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
            self.closeButton.frame = CGRectMake(20, 50, 44, 44);
            self.closeButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
            self.closeButton.layer.cornerRadius = 22;
            [self.closeButton setTitle:@"←" forState:UIControlStateNormal];
            self.closeButton.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
            [self.closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
            [topVC.view addSubview:self.closeButton];
            
            // 创建圆形拍照按钮
            CGFloat buttonSize = 70;
            self.captureButton = [UIButton buttonWithType:UIButtonTypeCustom];
            self.captureButton.frame = CGRectMake(
                (topVC.view.bounds.size.width - buttonSize) / 2,
                topVC.view.bounds.size.height - buttonSize - 40,
                buttonSize,
                buttonSize
            );
            self.captureButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
            self.captureButton.layer.cornerRadius = buttonSize / 2;
            self.captureButton.layer.borderWidth = 3;
            self.captureButton.layer.borderColor = [UIColor whiteColor].CGColor;
            [self.captureButton addTarget:self action:@selector(captureButtonTapped) forControlEvents:UIControlEventTouchUpInside];
            [topVC.view addSubview:self.captureButton];
            
            // 启动会话
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self.multiCamSession startRunning];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self addLog:@"✅ 双摄预览已开启，点击拍照按钮拍摄"];
                });
            });
            
        } @catch (NSException *exception) {
            [self addLog:[NSString stringWithFormat:@"❌ 设置双摄时崩溃: %@", exception.reason]];
            [self sendResult:NO message:exception.reason callback:self.currentCallback];
        }
    });
}

- (void)captureButtonTapped {
    if (self.isTakingPhoto) {
        [self addLog:@"正在拍照中，请稍后..."];
        return;
    }
    
    [self addLog:@"📷 开始拍照"];
    self.isTakingPhoto = YES;
    
    self.waitingForBackPhoto = YES;
    self.waitingForFrontPhoto = YES;
    self.backImage = nil;
    self.frontImage = nil;
}

- (void)closeDualCameraAndCleanup {
    [self addLog:@"关闭双摄并释放资源"];
    
    if (self.multiCamSession) {
        [self.multiCamSession stopRunning];
        
        if (self.backOutput) {
            [self.backOutput setSampleBufferDelegate:nil queue:NULL];
        }
        if (self.frontOutput) {
            [self.frontOutput setSampleBufferDelegate:nil queue:NULL];
        }
        
        [self.backPreviewView removeFromSuperview];
        [self.frontPreviewView removeFromSuperview];
        [self.closeButton removeFromSuperview];
        [self.captureButton removeFromSuperview];
        
        self.multiCamSession = nil;
        self.backInput = nil;
        self.frontInput = nil;
        self.backOutput = nil;
        self.frontOutput = nil;
        self.backImageView = nil;
        self.frontImageView = nil;
        self.backPreviewView = nil;
        self.frontPreviewView = nil;
        self.closeButton = nil;
        self.captureButton = nil;
        
        [self addLog:@"✅ 资源已释放"];
    }
}

- (void)closeButtonTapped {
    [self addLog:@"用户点击返回，取消拍照"];
    [self closeDualCameraAndCleanup];
    [self sendResult:NO message:@"用户取消" callback:self.currentCallback];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer) return;
    
    UIImageView *targetImageView = nil;
    
    if (output == self.backOutput) {
        targetImageView = self.backImageView;
    } else if (output == self.frontOutput) {
        targetImageView = self.frontImageView;
    }
    
    if (!targetImageView) return;
    
    UIImage *image = [self imageFromSampleBuffer:sampleBuffer];
    if (image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (targetImageView.superview) {
                targetImageView.image = image;
            }
            
            if (self.isTakingPhoto) {
                if (output == self.backOutput) {
                    self.backImage = image;
                    self.waitingForBackPhoto = NO;
                    [self addLog:@"✅ 后置照片已捕获"];
                } else if (output == self.frontOutput) {
                    self.frontImage = image;
                    self.waitingForFrontPhoto = NO;
                    [self addLog:@"✅ 前置照片已捕获"];
                }
                
                if (!self.waitingForBackPhoto && !self.waitingForFrontPhoto) {
                    [self saveBothPhotosAndClose];
                }
            }
        });
    }
}

- (void)saveBothPhotosAndClose {
    [self addLog:@"开始保存前后照片..."];
    
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
            if (newStatus == PHAuthorizationStatusAuthorized) {
                [self performSaveBothPhotosAndClose];
            } else {
                [self addLog:@"❌ 相册权限未授权"];
                [self closeDualCameraAndCleanup];
                [self sendResult:NO message:@"需要相册权限" callback:self.currentCallback];
                self.isTakingPhoto = NO;
            }
        }];
    } else if (status == PHAuthorizationStatusAuthorized) {
        [self performSaveBothPhotosAndClose];
    } else {
        [self addLog:@"❌ 相册权限未授权"];
        [self closeDualCameraAndCleanup];
        [self sendResult:NO message:@"请先在设置中开启相册权限" callback:self.currentCallback];
        self.isTakingPhoto = NO;
    }
}

- (void)performSaveBothPhotosAndClose {
    __block NSString *backPath = nil;
    __block NSString *frontPath = nil;
    __block NSError *backError = nil;
    __block NSError *frontError = nil;
    
    dispatch_group_t group = dispatch_group_create();
    
    if (self.backImage) {
        dispatch_group_enter(group);
        [self saveImageToPhotoLibrary:self.backImage completion:^(NSString *path, NSError *error) {
            backPath = path;
            backError = error;
            dispatch_group_leave(group);
        }];
    }
    
    if (self.frontImage) {
        dispatch_group_enter(group);
        [self saveImageToPhotoLibrary:self.frontImage completion:^(NSString *path, NSError *error) {
            frontPath = path;
            frontError = error;
            dispatch_group_leave(group);
        }];
    }
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self addLog:@"照片保存完成，关闭双摄"];
        [self closeDualCameraAndCleanup];
        
        if (backError || frontError) {
            [self sendResult:NO message:@"部分照片保存失败" callback:self.currentCallback];
        } else {
            [self sendPhotoResult:backPath frontPath:frontPath];
        }
        
        self.isTakingPhoto = NO;
    });
}

- (UIImage *)imageFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return nil;
    
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    if (!self.colorSpace) {
        self.colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, self.colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    
    CGImageRelease(cgImage);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    
    return image;
}

#pragma mark - 获取当前视图控制器

- (UIViewController *)getTopViewController {
    UIViewController *vc = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        vc = window.rootViewController;
                        break;
                    }
                }
            }
        }
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        vc = [UIApplication sharedApplication].keyWindow.rootViewController;
        #pragma clang diagnostic pop
    }
    
    UIViewController *currentShowingVC = [self findCurrentShowingViewControllerFrom:vc];
    return currentShowingVC;
}

- (UIViewController *)findCurrentShowingViewControllerFrom:(UIViewController *)vc {
    UIViewController *currentShowingVC;
    if ([vc presentedViewController]) {
        UIViewController *nextRootVC = [vc presentedViewController];
        currentShowingVC = [self findCurrentShowingViewControllerFrom:nextRootVC];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *nextRootVC = [(UITabBarController *)vc selectedViewController];
        currentShowingVC = [self findCurrentShowingViewControllerFrom:nextRootVC];
    } else if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *nextRootVC = [(UINavigationController *)vc visibleViewController];
        currentShowingVC = [self findCurrentShowingViewControllerFrom:nextRootVC];
    } else {
        currentShowingVC = vc;
    }
    return currentShowingVC;
}

- (void)dealloc {
    if (self.colorSpace) {
        CGColorSpaceRelease(self.colorSpace);
    }
}

@end
