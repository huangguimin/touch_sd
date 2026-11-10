// OpenCV side of Touch SD: image quality, SIFT + RANSAC matching, the enrolment mosaic.
// A line-by-line port of host/fpgui/{image,matcher,mosaic}.py against the same OpenCV
// (5.0.0, built by scripts/build_opencv.sh), so the app accepts and rejects exactly what
// the Python tools do.  Images cross this boundary as NSData:
//   raw    152 x 35 bytes, row-major: 152 rows along the sensor's long side, 35 columns
//   output RGBA, 4 bytes per pixel, with its width and height
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The matcher and quality settings (fpdb/settings.json; host/fpgui/settings.py).
@interface FPParams : NSObject
@property (nonatomic) double blockMean;
@property (nonatomic) double blockStd;
@property (nonatomic) double minCoverage;
@property (nonatomic) double minR;
@property (nonatomic) double siftContrast;
@property (nonatomic) double ratio;
@property (nonatomic) double ransacPx;
@property (nonatomic) double maxRot;
@property (nonatomic) NSInteger matchScore;
@property (nonatomic) double matchStrongNcc;
@property (nonatomic) NSInteger matchWeak;
@property (nonatomic) double matchNcc;
@end

typedef NS_ENUM(NSInteger, FPQualityCode) {
    FPQualityGood = 0,
    FPQualityPartial = 1,
    FPQualityInsufficient = 2,
};

/// image.Quality
@interface FPQuality : NSObject
@property (nonatomic, readonly) double mean;
@property (nonatomic, readonly) double r;
@property (nonatomic, readonly) double coverage;
@property (nonatomic, readonly) FPQualityCode code;
+ (instancetype)qualityOf:(NSData *)raw params:(FPParams *)p NS_SWIFT_NAME(measure(_:params:));
/// image.contrast: mean |row r - row r+4|
+ (double)contrast:(NSData *)raw;
@end

/// matcher.Sample: features of one 152 x 35 image.
@interface FPSample : NSObject
- (instancetype)initWithRaw:(NSData *)raw params:(FPParams *)p;
@property (nonatomic, readonly) NSData *raw;
@property (nonatomic, readonly) NSInteger keypointCount;
/// The normalised, 3x enlarged image the features come from, turned so the long side is
/// horizontal (grey, 1 byte per pixel).
- (NSData *)normLandscapeWidth:(NSInteger *)w height:(NSInteger *)h;
@end

/// matcher.Match
@interface FPMatch : NSObject
@property (nonatomic, readonly) NSInteger score;    ///< RANSAC inliers
@property (nonatomic, readonly) NSInteger good;     ///< matches through the ratio test
@property (nonatomic, readonly) double ncc;         ///< aligned pixel correlation, -1 if not computed
@property (nonatomic, readonly) double overlap;
@property (nonatomic, readonly) BOOL accepted;
/// strength() ordering: accepted, then score, then ncc.
- (BOOL)isStrongerThan:(FPMatch *)other NS_SWIFT_NAME(isStronger(than:));
+ (FPMatch *)empty;
@end

@interface FPMatcher : NSObject
+ (FPMatch *)match:(FPSample *)probe to:(FPSample *)tmpl params:(FPParams *)p;
/// best_match: the strongest match against samples; index -1 when none beats an empty match.
+ (FPMatch *)best:(FPSample *)probe in:(NSArray<FPSample *> *)samples params:(FPParams *)p
            index:(NSInteger *_Nullable)index;
/// draw_match: both normalised images, probe above, inlier pairs joined (RGBA).
+ (NSData *)drawMatch:(FPSample *)probe to:(FPSample *)tmpl match:(FPMatch *)m
                width:(NSInteger *)w height:(NSInteger *)h;
@end

/// mosaic.Mosaic: enrolled samples stitched into the area covered so far.
@interface FPMosaic : NSObject
- (instancetype)initWithParams:(FPParams *)p;
- (void)add:(FPSample *)s;
@property (nonatomic, readonly) NSInteger count;
/// RGBA image or nil when empty.  highlight: sample index to outline, -1 for none.
/// area: covered mm2; islands: samples per island, largest first; highlightAlone: the
/// highlighted sample overlaps nothing else.
- (nullable NSData *)render:(NSInteger)highlight width:(NSInteger *)w height:(NSInteger *)h
                       area:(double *)area islands:(NSArray<NSNumber *> *_Nullable *_Nullable)islands
             highlightAlone:(BOOL *)alone;
@end

NS_ASSUME_NONNULL_END
