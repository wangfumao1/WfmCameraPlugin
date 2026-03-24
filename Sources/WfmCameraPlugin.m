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

// 水印相关
@property (nonatomic, strong) NSString *watermarkLocation;
@property (nonatomic, strong) NSString *watermarkLatitude;
@property (nonatomic, strong) NSString *watermarkLongitude;
@property (nonatomic, strong) NSString *watermarkOperator;

// 摄像头格式相关方法
- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device;
- (BOOL)configureBestFormatForDevice:(AVCaptureDevice *)device;

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
            
            // 压缩图片质量到 0.7，保证文件大小
            NSData *imageData = UIImageJPEGRepresentation(image, 0.7);
            // 如果仍然太大，继续压缩
            while (imageData.length > 1024 * 1024 && imageData.length > 0) {
                static CGFloat compression = 0.65;
                compression -= 0.05;
                if (compression < 0.1) break;
                imageData = UIImageJPEGRepresentation(image, compression);
            }
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

#pragma mark - 获取摄像头当前分辨率
- (CGSize)getCameraResolution:(AVCaptureDevice *)device {
    if (!device || !device.activeFormat) {
        return CGSizeMake(1920, 1080);
    }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    return CGSizeMake(dims.width, dims.height);
}

- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    self.currentCallback = callback;
    self.isTakingPhoto = NO;
    
    // 解析水印相关参数
    self.watermarkLocation = options[@"location"] ?: @"";
    self.watermarkLatitude = options[@"latitude"] ?: @"";
    self.watermarkLongitude = options[@"longitude"] ?: @"";
    self.watermarkOperator = options[@"operator"] ?: @"";
    
    [self addLog:@"========== 打开双摄 =========="];
    [self addLog:[NSString stringWithFormat:@"水印参数: 地点=%@, 纬度=%@, 经度=%@, 操作人=%@", 
                 self.watermarkLocation, self.watermarkLatitude, self.watermarkLongitude, self.watermarkOperator]];
    
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
            self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
            
            AVCaptureDevice *backCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                              mediaType:AVMediaTypeVideo
                                                                               position:AVCaptureDevicePositionBack];
            if (!backCamera) {
                [self addLog:@"❌ 找不到后置摄像头"];
                [self sendResult:NO message:@"找不到后置摄像头" callback:self.currentCallback];
                return;
            }
            
            [self configureBestFormatForDevice:backCamera];
            
            AVCaptureDevice *frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                               mediaType:AVMediaTypeVideo
                                                                                position:AVCaptureDevicePositionFront];
            if (!frontCamera) {
                [self addLog:@"❌ 找不到前置摄像头"];
                [self sendResult:NO message:@"找不到前置摄像头" callback:self.currentCallback];
                return;
            }
            
            [self configureBestFormatForDevice:frontCamera];
            
            CGSize backResolution = [self getCameraResolution:backCamera];
            [self addLog:[NSString stringWithFormat:@"摄像头原始分辨率: %.0fx%.0f", backResolution.width, backResolution.height]];
            
            CGFloat displayAspectRatio = backResolution.height / backResolution.width;
            [self addLog:[NSString stringWithFormat:@"竖屏显示比例: %.2f (高/宽)", displayAspectRatio]];
            
            // 添加输入
            NSError *error = nil;
            self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&error];
            if (error || ![self.multiCamSession canAddInput:self.backInput]) {
                [self addLog:@"❌ 无法添加后置输入"];
                [self sendResult:NO message:@"后置摄像头添加失败" callback:self.currentCallback];
                return;
            }
            [self.multiCamSession addInput:self.backInput];
            [self addLog:@"✅ 后置输入添加成功"];
            
            self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
            if (error || ![self.multiCamSession canAddInput:self.frontInput]) {
                [self addLog:@"❌ 无法添加前置输入"];
                [self sendResult:NO message:@"前置摄像头添加失败" callback:self.currentCallback];
                return;
            }
            [self.multiCamSession addInput:self.frontInput];
            [self addLog:@"✅ 前置输入添加成功"];
            
            // 添加视频输出
            self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.backOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.backOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.backOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.backOutput];
                if (self.backInput.ports.count > 0) {
                    AVCaptureConnection *backConnection = [AVCaptureConnection connectionWithInputPorts:self.backInput.ports output:self.backOutput];
                    if (backConnection && [self.multiCamSession canAddConnection:backConnection]) {
                        [self.multiCamSession addConnection:backConnection];
                        [self addLog:@"✅ 后置视频输出添加成功"];
                    }
                }
            }
            
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
                            [self addLog:@"✅ 前置视频输出添加成功"];
                        }
                    }
                }
            }
            
            // 获取视图
            UIViewController *topVC = [self getTopViewController];
            if (!topVC) {
                [self addLog:@"❌ 无法获取当前视图"];
                [self sendResult:NO message:@"无法获取当前视图" callback:self.currentCallback];
                return;
            }
            
            // ========== 后置预览：至少一个方向铺满屏幕 ==========
            CGFloat viewWidth = topVC.view.bounds.size.width;
            CGFloat viewHeight = topVC.view.bounds.size.height;

            // 摄像头旋转后的竖屏比例 = 原始高度 / 原始宽度
            CGFloat videoAspectRatio = backResolution.height / backResolution.width;
            CGFloat screenAspectRatio = viewHeight / viewWidth;

            CGFloat targetWidth, targetHeight;  // 旋转前的目标尺寸

            if (videoAspectRatio > screenAspectRatio) {
                // 画面更瘦高，按高度铺满屏幕，宽度居中
                // 旋转前：高度 = viewHeight，宽度 = viewHeight / videoAspectRatio
                targetHeight = viewHeight;
                targetWidth = targetHeight / videoAspectRatio;
            } else {
                // 画面更矮宽，按宽度铺满屏幕，高度居中
                // 旋转前：宽度 = viewWidth，高度 = viewWidth * videoAspectRatio
                targetWidth = viewWidth;
                targetHeight = targetWidth * videoAspectRatio;
            }

            CGFloat fitX = (viewWidth - targetWidth) / 2;
            CGFloat fitY = (viewHeight - targetHeight) / 2;

            [self addLog:[NSString stringWithFormat:@"屏幕比例: %.2f, 画面比例: %.2f", screenAspectRatio, videoAspectRatio]];
            [self addLog:[NSString stringWithFormat:@"目标区域(旋转前): (%.0f,%.0f,%.0f,%.0f)", fitX, fitY, targetWidth, targetHeight]];

            // 后置预览
            self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
            self.backPreviewView.backgroundColor = [UIColor blackColor];
            [topVC.view addSubview:self.backPreviewView];

            // 注意：旋转后宽高交换，所以 ImageView 的 frame 要交换宽高
            self.backImageView = [[UIImageView alloc] initWithFrame:CGRectMake(fitX, fitY, targetHeight, targetWidth)];
            self.backImageView.contentMode = UIViewContentModeScaleAspectFill;
            self.backImageView.backgroundColor = [UIColor clearColor];
            // 旋转90度
            self.backImageView.transform = CGAffineTransformMakeRotation(M_PI_2);
            [self.backPreviewView addSubview:self.backImageView];
            [self addLog:@"✅ 后置预览视图已创建（至少一个方向铺满）"];
            
            // 前置小窗 - 旋转后宽高交换
            // 小窗固定宽度 120，高度按画面比例计算
            CGFloat smallWidth = 120;
            CGFloat smallHeight = smallWidth * videoAspectRatio;  // 注意：旋转后高度 = 宽度 × 画面比例
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
            // 前置旋转90度 + 镜像
            self.frontImageView.transform = CGAffineTransformMakeRotation(M_PI_2);
            self.frontImageView.transform = CGAffineTransformScale(self.frontImageView.transform, -1, 1);
            [self.frontPreviewView addSubview:self.frontImageView];
            [self addLog:@"✅ 前置预览小窗已创建"];
            
            // 按钮
            self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
            self.closeButton.frame = CGRectMake(20, 50, 44, 44);
            self.closeButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
            self.closeButton.layer.cornerRadius = 22;
            [self.closeButton setTitle:@"←" forState:UIControlStateNormal];
            self.closeButton.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
            [self.closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
            [topVC.view addSubview:self.closeButton];
            
            self.captureButton = [UIButton buttonWithType:UIButtonTypeCustom];
            CGFloat buttonSize = 70;
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
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self.multiCamSession startRunning];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self addLog:@"✅ 双摄预览已开启"];
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
                if (output == self.backOutput && self.waitingForBackPhoto) {
                    // 后置照片：旋转90度 + 添加水印
                    UIImage *rotatedImage = [self rotateImage:image byDegrees:90];
                    UIImage *watermarkedImage = [self addWatermarkToImage:rotatedImage];
                    self.backImage = watermarkedImage;
                    self.waitingForBackPhoto = NO;
                    [self addLog:@"✅ 后置照片已捕获"];
                } else if (output == self.frontOutput && self.waitingForFrontPhoto) {
                    // 前置照片：旋转90度 + 镜像 + 旋转180度修正
                    UIImage *rotatedImage = [self rotateImage:image byDegrees:90];
                    rotatedImage = [self flipImageHorizontally:rotatedImage];
                    rotatedImage = [self rotateImage:rotatedImage byDegrees:180];
                    UIImage *watermarkedImage = [self addWatermarkToImage:rotatedImage];
                    self.frontImage = watermarkedImage;
                    self.waitingForFrontPhoto = NO;
                    [self addLog:@"✅ 前置照片已捕获"];
                }
                
                if (!self.waitingForBackPhoto && !self.waitingForFrontPhoto) {
                    self.isTakingPhoto = NO;
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

#pragma mark - 图像处理

- (UIImage *)rotateImage:(UIImage *)image byDegrees:(CGFloat)degrees {
    CGAffineTransform transform = CGAffineTransformMakeRotation(degrees * M_PI / 180.0);
    CGSize rotatedSize = CGSizeMake(image.size.height, image.size.width);
    
    UIGraphicsBeginImageContext(rotatedSize);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, rotatedSize.width / 2, rotatedSize.height / 2);
    CGContextRotateCTM(context, degrees * M_PI / 180.0);
    [image drawInRect:CGRectMake(-image.size.width / 2, -image.size.height / 2, image.size.width, image.size.height)];
    UIImage *rotatedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return rotatedImage;
}

- (UIImage *)flipImageHorizontally:(UIImage *)image {
    UIGraphicsBeginImageContext(image.size);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, image.size.width, 0);
    CGContextScaleCTM(context, -1.0, 1.0);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *flippedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return flippedImage;
}

#pragma mark - 水印（仿安卓样式：半透明背景、多行、不同颜色、左下角）

- (NSArray *)getWatermarkTexts {
    NSDate *now = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timeString = [formatter stringFromDate:now];
    
    NSString *location = self.watermarkLocation.length > 0 ? self.watermarkLocation : @"未知";
    NSString *lngLat = @"";
    if (self.watermarkLatitude.length > 0 && self.watermarkLongitude.length > 0) {
        lngLat = [NSString stringWithFormat:@"%@,%@", self.watermarkLatitude, self.watermarkLongitude];
    } else {
        lngLat = @"未知";
    }
    NSString *operatorName = self.watermarkOperator.length > 0 ? self.watermarkOperator : @"未知";
    
    return @[
        [NSString stringWithFormat:@"拍摄时间：%@", timeString],
        [NSString stringWithFormat:@"拍摄地点：%@", location],
        [NSString stringWithFormat:@"经纬度：%@", lngLat],
        [NSString stringWithFormat:@"操作人：%@", operatorName],
        @"智慧电梯维保平台"
    ];
}

- (NSArray *)getWatermarkColors {
    return @[
        [UIColor whiteColor],                                      // 拍摄时间 - 白色
        [UIColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0],  // 黄色 - 地点
        [UIColor colorWithRed:0.0 green:1.0 blue:0.6 alpha:1.0],  // 嫩绿色 - 经纬度
        [UIColor colorWithRed:0.0 green:1.0 blue:1.0 alpha:1.0],  // 青色 - 操作人
        [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]   // 橙色 - 平台
    ];
}

- (UIImage *)addWatermarkToImage:(UIImage *)image {
    CGSize imageSize = image.size;
    
    // 动态计算字体大小（基于图片宽度）
    CGFloat fontSize = 14.0;
    if (imageSize.width > 2000) fontSize = 18.0;
    else if (imageSize.width > 1000) fontSize = 16.0;
    else fontSize = 14.0;
    
    CGFloat padding = 10.0;
    CGFloat spacing = 4.0;
    CGFloat margin = 16.0;
    CGFloat cornerRadius = 6.0;
    
    NSArray *texts = [self getWatermarkTexts];
    NSArray *colors = [self getWatermarkColors];
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium];
    
    // 计算文本尺寸
    CGFloat maxTextWidth = 0;
    CGFloat totalTextHeight = 0;
    NSMutableArray *textHeights = [NSMutableArray array];
    
    for (NSString *text in texts) {
        NSDictionary *attrs = @{NSFontAttributeName: font};
        CGRect rect = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:attrs
                                         context:nil];
        maxTextWidth = MAX(maxTextWidth, rect.size.width);
        totalTextHeight += rect.size.height;
        [textHeights addObject:@(rect.size.height)];
    }
    totalTextHeight += spacing * (texts.count - 1);
    
    // 背景尺寸
    CGFloat bgWidth = maxTextWidth + padding * 2;
    CGFloat bgHeight = totalTextHeight + padding * 2;
    
    // 左下角位置
    CGFloat bgX = margin;
    CGFloat bgY = imageSize.height - margin - bgHeight;
    
    // 开始绘制
    UIGraphicsBeginImageContextWithOptions(imageSize, NO, 1.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // 1. 绘制原图
    [image drawInRect:CGRectMake(0, 0, imageSize.width, imageSize.height)];
    
    // 2. 绘制半透明背景（黑色，alpha 0.5）
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(bgX, bgY, bgWidth, bgHeight)
                                                       cornerRadius:cornerRadius];
    [[UIColor colorWithWhite:0 alpha:0.5] setFill];
    [bgPath fill];
    
    // 3. 绘制细边框
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.5].CGColor);
    CGContextSetLineWidth(context, 1.0);
    UIBezierPath *borderPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(bgX + 0.5, bgY + 0.5, bgWidth - 1, bgHeight - 1)
                                                          cornerRadius:cornerRadius - 0.5];
    [borderPath stroke];
    
    // 4. 绘制文本
    CGFloat currentY = bgY + padding;
    for (NSInteger i = 0; i < texts.count; i++) {
        NSString *text = texts[i];
        UIColor *color = colors[i];
        CGFloat textHeight = [textHeights[i] floatValue];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color
        };
        
        CGFloat textX = bgX + padding;
        CGFloat textY = currentY + (textHeight - textHeight) / 2;
        [text drawAtPoint:CGPointMake(textX, textY) withAttributes:attrs];
        
        currentY += textHeight + spacing;
    }
    
    UIImage *watermarkedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return watermarkedImage;
}

#pragma mark - 摄像头格式配置

- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device {
    if (!device) return nil;
    
    AVCaptureDeviceFormat *bestFormat = nil;
    int maxArea = 0;
    
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        int area = dims.width * dims.height;
        float aspectRatio = (float)dims.width / (float)dims.height;
        BOOL isWideScreen = fabs(aspectRatio - 16.0/9.0) < 0.1;
        
        if (area > maxArea) {
            if (isWideScreen) {
                maxArea = area;
                bestFormat = format;
            } else if (!bestFormat) {
                maxArea = area;
                bestFormat = format;
            }
        }
    }
    
    return bestFormat;
}

- (BOOL)configureBestFormatForDevice:(AVCaptureDevice *)device {
    if (!device) return NO;
    
    AVCaptureDeviceFormat *bestFormat = [self bestFormatForDevice:device];
    if (!bestFormat) {
        [self addLog:@"⚠️ 未找到合适的格式"];
        return NO;
    }
    
    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        [self addLog:[NSString stringWithFormat:@"⚠️ 无法锁定摄像头: %@", error.localizedDescription]];
        return NO;
    }
    
    device.activeFormat = bestFormat;
    CMTime frameDuration = CMTimeMake(1, 30);
    device.activeVideoMinFrameDuration = frameDuration;
    device.activeVideoMaxFrameDuration = frameDuration;
    
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
    [self addLog:[NSString stringWithFormat:@"✅ 设置摄像头格式: %dx%d", dims.width, dims.height]];
    
    [device unlockForConfiguration];
    return YES;
}

- (void)dealloc {
    if (self.colorSpace) {
        CGColorSpaceRelease(self.colorSpace);
    }
}

@end
