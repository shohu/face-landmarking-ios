//
//  DlibWrapper.m
//  DisplayLiveSamples
//
//  Created by Luis Reisewitz on 16.05.16.
//  Copyright © 2016 ZweiGraf. All rights reserved.
//

#import "DlibWrapper.h"
#import <UIKit/UIKit.h>

#include <dlib/image_processing.h>
#include <dlib/image_io.h>

@interface DlibWrapper ()

@property (assign) BOOL prepared;
@property (assign) int eyeBlinkCount;

+ (std::vector<dlib::rectangle>)convertCGRectValueArray:(NSArray<NSValue *> *)rects;
+ (bool) isEyeBlink:(dlib::full_object_detection)shape;
+ (long) calcDisntace:(dlib::point)pointA with:(dlib::point)pointB;

@end
@implementation DlibWrapper {
    dlib::shape_predictor sp;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _prepared = NO;
        _eyeBlinkCount = 0;
    }
    return self;
}

- (void)prepare {
    NSString *modelFileName = [[NSBundle mainBundle] pathForResource:@"shape_predictor_68_face_landmarks" ofType:@"dat"];
    std::string modelFileNameCString = [modelFileName UTF8String];
    
    dlib::deserialize(modelFileNameCString) >> sp;
    
    // FIXME: test this stuff for memory leaks (cpp object destruction)
    self.prepared = YES;
}

- (void)doWorkOnSampleBuffer:(CMSampleBufferRef)sampleBuffer inRects:(NSArray<NSValue *> *)rects {
    
    if (!self.prepared) {
        [self prepare];
    }
    
    dlib::array2d<dlib::bgr_pixel> img;
    
    // MARK: magic
    // videoから取得した sampleBuffer を CVImageBufferRef に変換
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // イメージバッファのロック
    // CVImageBufferを取得したら、処理を始める前にこれをロックしないといけない。ロックしないと、カメラから送られてくるデータで次々と書き換えられてしまう事になる
    // https://news.mynavi.jp/itsearch/article/devsoft/1218
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    // イメージバッファ情報の取得
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    char *baseBuffer = (char *)CVPixelBufferGetBaseAddress(imageBuffer);
    
    // set_size expects rows, cols format
    img.set_size(height, width);
    
    // image data を dlib image formatにコピー
    // copy samplebuffer image data into dlib image format
    img.reset();
    long position = 0;
    while (img.move_next()) {
        // 参照渡し。img の element に結果新しいデータが入る
        dlib::bgr_pixel& pixel = img.element();

        // assuming bgra format here
        long bufferLocation = position * 4; //(row * width + column) * 4;
        char b = baseBuffer[bufferLocation];
        char g = baseBuffer[bufferLocation + 1];
        char r = baseBuffer[bufferLocation + 2];
        //        we do not need this
        //        char a = baseBuffer[bufferLocation + 3];
        
        dlib::bgr_pixel newpixel(b, g, r);
        pixel = newpixel;
        
        position++;
    }
    
    // ロック解除
    // unlock buffer again until we need it again
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    // convert the face bounds list to dlib format
    std::vector<dlib::rectangle> convertedRectangles = [DlibWrapper convertCGRectValueArray:rects];
    
    // 画面に表示される顔が１つであるときに処理する convertedRectangles の数が顔数
    if (convertedRectangles.size() == 1) {
//    for (unsigned long j = 0; j < convertedRectangles.size(); ++j)
//    {
        dlib::rectangle oneFaceRect = convertedRectangles[0];
        
        // 顔の輪郭取得
        // detect all landmarks
        dlib::full_object_detection shape = sp(img, oneFaceRect);
        
        // 顔の輪郭を描画する
        // and draw them into the image (samplebuffer)
        for (unsigned long k = 0; k < shape.num_parts(); k++) {
            dlib::point p = shape.part(k);
            dlib::rgb_pixel tmp_pixel = dlib::rgb_pixel(0, 255, 255);
            draw_solid_circle(img, p, 3, tmp_pixel);
        }
        
        // 瞳が閉じているかどうか（片方だけ
        if ([DlibWrapper isEyeBlink:shape]) {
            self.eyeBlinkCount++;
        }
//    }
    }
    
    // ロック
    // lets put everything back where it belongs
    CVPixelBufferLockBaseAddress(imageBuffer, 0);

    // copy dlib image data back into samplebuffer
    img.reset();
    position = 0;
    while (img.move_next()) {
        dlib::bgr_pixel& pixel = img.element();
        
        // assuming bgra format here
        long bufferLocation = position * 4; //(row * width + column) * 4;
        baseBuffer[bufferLocation] = pixel.blue;
        baseBuffer[bufferLocation + 1] = pixel.green;
        baseBuffer[bufferLocation + 2] = pixel.red;
        //        we do not need this
        //        char a = baseBuffer[bufferLocation + 3];
        
        position++;
    }
    
    // アンロック
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
}

+ (std::vector<dlib::rectangle>)convertCGRectValueArray:(NSArray<NSValue *> *)rects {
    std::vector<dlib::rectangle> myConvertedRects;
    for (NSValue *rectValue in rects) {
        CGRect rect = [rectValue CGRectValue];
        long left = rect.origin.x;
        long top = rect.origin.y;
        long right = left + rect.size.width;
        long bottom = top + rect.size.height;
        dlib::rectangle dlibRect(left, top, right, bottom);

        myConvertedRects.push_back(dlibRect);
    }
    return myConvertedRects;
}

- (int) getEyeBlinkCount {
    return self.eyeBlinkCount;
}

+ (bool) isEyeBlink:(dlib::full_object_detection)shape {
    double ear = [DlibWrapper calcEAR:shape];
    if (ear < 0.40) {
        return true;
    }
    return false;

//    dlib::point a = shape.part(37);

//    long eye_top_y = MIN(shape.part(37).y(), shape.part(38).y());
//    long eye_bottom_y = MAX(shape.part(41).y(), shape.part(40).y());
//
//    // TODO: 以下の数値は調整する。画質によって変わってくる？要確認
//    if (labs(eye_top_y - eye_bottom_y) < 22) {
//        NSLog(@"Eye blink detected !! : %ld", labs(eye_top_y - eye_bottom_y));
//        return true;
//    }
//    return false;
}

// EAR(eyes aspect ratio)を求める
+ (double) calcEAR:(dlib::full_object_detection)shape {
    // 瞳の座標取得
    // http://mizutanikirin.net/unity-dlib-facelandmark-detector%E3%81%A7%E9%A1%94%E8%AA%8D%E8%AD%98
    
    // 左目
    long a = [DlibWrapper calcDisntace:shape.part(37) with:shape.part(41)];
    long b = [DlibWrapper calcDisntace:shape.part(38) with:shape.part(40)];
    long c = [DlibWrapper calcDisntace:shape.part(36) with:shape.part(39)];
    double eye_ear = (a + b) / (2.0 * c);
    double left_eye_ear = round(eye_ear*1000)/1000; // 小数点4位で四捨五入
    
    // 右目
    a = [DlibWrapper calcDisntace:shape.part(43) with:shape.part(47)];
    b = [DlibWrapper calcDisntace:shape.part(44) with:shape.part(46)];
    c = [DlibWrapper calcDisntace:shape.part(42) with:shape.part(45)];
    eye_ear = (a + b) / (2.0 * c);
    double right_eye_ear = round(eye_ear*1000)/1000; // 小数点4位で四捨五入
    
    return left_eye_ear + right_eye_ear;
}

// ユークリッド(点と点の)距離
+ (long)calcDisntace:(dlib::point)pointA with:(dlib::point)pointB{
    long xDistance = pointA.x() - pointB.x();
    long yDistance = pointA.y() - pointB.y();
    long distance = sqrtf(xDistance*xDistance + yDistance*yDistance);
    return distance;
}

@end
