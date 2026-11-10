// Port of host/fpgui/image.py, matcher.py and mosaic.py.  Kept in the same order and with
// the same float32 arithmetic as the numpy code; where numpy and OpenCV differ (astype
// truncates, convertTo rounds) the numpy behaviour is reproduced by hand.
#import "CvBridge.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/geometry.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>

static const int H = 152;      // rows along the sensor's long side
static const int W = 35;
static const int SCALE = 3;    // features come from a 3x enlarged image (matcher.SCALE)
static const double PX_PER_MM = 508.0 / 25.4 * SCALE;

static cv::Mat rawMat(NSData *raw) {
    NSCAssert(raw.length == (NSUInteger)(H * W), @"raw image must be 152 x 35");
    return cv::Mat(H, W, CV_8U, (void *)raw.bytes).clone();
}

static NSData *rgbaFromBgr(const cv::Mat &bgr, NSInteger *w, NSInteger *h) {
    cv::Mat rgba;
    cv::cvtColor(bgr, rgba, cv::COLOR_BGR2RGBA);
    *w = rgba.cols;
    *h = rgba.rows;
    return [NSData dataWithBytes:rgba.data length:rgba.total() * rgba.elemSize()];
}

// image.block_cover: 16-row blocks whose mean and spread both say "finger".
static std::vector<bool> blockCover(const cv::Mat &a, double minMean, double minStd,
                                    int rows = 16) {
    int n = a.rows / rows;
    std::vector<bool> out(n);
    for (int i = 0; i < n; ++i) {
        cv::Mat b;
        a.rowRange(i * rows, (i + 1) * rows).convertTo(b, CV_32F);
        cv::Scalar mean, sd;
        cv::meanStdDev(b, mean, sd);
        out[i] = mean[0] > minMean && sd[0] > minStd;
    }
    return out;
}

static double contrastOf(const cv::Mat &a) {
    double sum = 0;
    for (int r = 0; r + 4 < a.rows; ++r) {
        for (int c = 0; c < a.cols; ++c) {
            sum += std::abs((int)a.at<uint8_t>(r + 4, c) - (int)a.at<uint8_t>(r, c));
        }
    }
    return sum / ((a.rows - 4) * a.cols);
}

// ---------------------------------------------------------------------------------------

@implementation FPParams
- (instancetype)init {
    if ((self = [super init])) {
        _blockMean = 25; _blockStd = 10; _minCoverage = 0.6; _minR = 8.0;
        _siftContrast = 0.02; _ratio = 0.8; _ransacPx = 3.0; _maxRot = 40.0;
        _matchScore = 8; _matchStrongNcc = 0.35; _matchWeak = 5; _matchNcc = 0.75;
    }
    return self;
}
@end

@implementation FPQuality
+ (instancetype)qualityOf:(NSData *)raw params:(FPParams *)p {
    FPQuality *q = [FPQuality new];
    cv::Mat a = rawMat(raw);
    q->_mean = cv::mean(a)[0];
    q->_r = contrastOf(a);
    std::vector<bool> cov = blockCover(a, p.blockMean, p.blockStd);
    q->_coverage = (double)std::count(cov.begin(), cov.end(), true) / cov.size();
    if (q->_coverage < p.minCoverage) {
        q->_code = FPQualityPartial;
    } else if (q->_r < p.minR) {
        q->_code = FPQualityInsufficient;
    } else {
        q->_code = FPQualityGood;
    }
    return q;
}

+ (double)contrast:(NSData *)raw {
    return contrastOf(rawMat(raw));
}
@end

// ---------------------------------------------------------------------------------------

@interface FPSample () {
@public
    cv::Mat _norm;   // CV_8U, 456 x 105
    cv::Mat _mask;   // CV_8U 0/255, same size as _norm
    cv::Mat _pix;    // CV_32F, 152 x 35
    cv::Mat _pmask;  // CV_8U 0/1, 152 x 35
    std::vector<cv::KeyPoint> _kp;
    cv::Mat _des;
}
@end

@implementation FPSample
- (instancetype)initWithRaw:(NSData *)raw params:(FPParams *)p {
    if (!(self = [super init])) {
        return nil;
    }
    _raw = [raw copy];
    cv::Mat r8 = rawMat(raw);
    cv::Mat g;
    r8.convertTo(g, CV_32F);
    // Local normalisation: keep only the ridge/valley swing, not pressure or offset.
    cv::Mat mu, sdb, sd, gb3, gb08;
    cv::GaussianBlur(g, mu, cv::Size(0, 0), 6);
    cv::Mat d = g - mu;
    cv::GaussianBlur(d.mul(d), sdb, cv::Size(0, 0), 6);
    cv::sqrt(sdb, sd);
    sd += 1e-3f;
    cv::Mat n = d / sd;
    n = cv::max(n, -2.5f);
    n = cv::min(n, 2.5f);

    std::vector<bool> cov = blockCover(r8, p.blockMean, p.blockStd);
    auto rowCovered = [&](int r) { return cov[std::min(r / 16, (int)cov.size() - 1)]; };
    cv::Mat mask(H, W, CV_8U);
    for (int r = 0; r < H; ++r) {
        mask.row(r).setTo(rowCovered(r) ? 255 : 0);
    }
    // Pixel mask for the correlation check: also drop the dark, unpressed area.
    cv::GaussianBlur(g, gb3, cv::Size(0, 0), 3);
    cv::Mat pm(H, W, CV_8U);
    for (int r = 0; r < H; ++r) {
        for (int c = 0; c < W; ++c) {
            pm.at<uint8_t>(r, c) = (rowCovered(r) && gb3.at<float>(r, c) > p.blockMean) ? 1 : 0;
        }
    }
    cv::erode(pm, _pmask, cv::Mat::ones(3, 3, CV_8U));
    cv::GaussianBlur(g, gb08, cv::Size(0, 0), 0.8);
    _pix = (gb08 - mu) / sd;

    // ((n + 2.5) * 51).astype(uint8): float32 arithmetic, then truncation.
    cv::Mat n8(H, W, CV_8U);
    for (int r = 0; r < H; ++r) {
        for (int c = 0; c < W; ++c) {
            float v = (n.at<float>(r, c) + 2.5f) * 51.0f;
            n8.at<uint8_t>(r, c) = (uint8_t)(int)v;
        }
    }
    cv::resize(n8, _norm, cv::Size(), SCALE, SCALE, cv::INTER_CUBIC);
    cv::resize(mask, _mask, cv::Size(_norm.cols, _norm.rows), 0, 0, cv::INTER_NEAREST);
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create(0, 3, p.siftContrast, 10, 1.6);
    sift->detectAndCompute(_norm, _mask, _kp, _des);
    return self;
}

- (NSInteger)keypointCount {
    return (NSInteger)_kp.size();
}

- (NSData *)normLandscapeWidth:(NSInteger *)w height:(NSInteger *)h {
    cv::Mat rot;
    cv::rotate(_norm, rot, cv::ROTATE_90_COUNTERCLOCKWISE);
    *w = rot.cols;
    *h = rot.rows;
    return [NSData dataWithBytes:rot.data length:rot.total()];
}
@end

// ---------------------------------------------------------------------------------------

@interface FPMatch () {
@public
    cv::Mat _M;  // 2 x 3 CV_64F, probe (enlarged) coordinates -> template; empty if none
    std::vector<std::pair<int, int>> _pairs;
}
@property (nonatomic, readwrite) NSInteger score;
@property (nonatomic, readwrite) NSInteger good;
@property (nonatomic, readwrite) double ncc;
@property (nonatomic, readwrite) double overlap;
@property (nonatomic, readwrite) BOOL accepted;
@end

@implementation FPMatch
- (instancetype)init {
    if ((self = [super init])) {
        _ncc = -1.0;
    }
    return self;
}

+ (FPMatch *)empty {
    return [FPMatch new];
}

- (BOOL)isStrongerThan:(FPMatch *)o {
    if (_accepted != o.accepted) {
        return _accepted;
    }
    if (_score != o.score) {
        return _score > o.score;
    }
    return _ncc > o.ncc;
}
@end

// matcher.aligned_ncc
static double alignedNcc(FPSample *probe, FPSample *tmpl, const cv::Mat &M, int minPx = 400) {
    cv::Mat Mo;
    M.convertTo(Mo, CV_32F);
    Mo.at<float>(0, 2) /= SCALE;
    Mo.at<float>(1, 2) /= SCALE;
    cv::Size sz(tmpl->_pix.cols, tmpl->_pix.rows);
    cv::Mat wp, wm;
    cv::warpAffine(probe->_pix, wp, Mo, sz);
    cv::warpAffine(probe->_pmask, wm, Mo, sz, cv::INTER_NEAREST);
    std::vector<float> a, b;
    for (int r = 0; r < sz.height; ++r) {
        for (int c = 0; c < sz.width; ++c) {
            if (wm.at<uint8_t>(r, c) && tmpl->_pmask.at<uint8_t>(r, c)) {
                a.push_back(wp.at<float>(r, c));
                b.push_back(tmpl->_pix.at<float>(r, c));
            }
        }
    }
    if ((int)a.size() < minPx) {
        return -1.0;
    }
    double ma = 0, mb = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        ma += a[i];
        mb += b[i];
    }
    ma /= a.size();
    mb /= b.size();
    double sab = 0, saa = 0, sbb = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        double x = a[i] - ma, y = b[i] - mb;
        sab += x * y;
        saa += x * x;
        sbb += y * y;
    }
    return sab / std::sqrt(saa * sbb + 1e-9);
}

static FPMatch *matchSamples(FPSample *probe, FPSample *tmpl, FPParams *p) {
    FPMatch *r = [FPMatch new];
    if (probe->_des.empty() || tmpl->_des.empty() || probe->_kp.size() < 3 || tmpl->_kp.size() < 3) {
        return r;
    }
    std::vector<std::vector<cv::DMatch>> knn;
    cv::BFMatcher(cv::NORM_L2).knnMatch(probe->_des, tmpl->_des, knn, 2);
    std::vector<cv::DMatch> good;
    for (const auto &m : knn) {
        if (m.size() == 2 && (double)m[0].distance < p.ratio * (double)m[1].distance) {
            good.push_back(m[0]);
        }
    }
    r.good = (NSInteger)good.size();
    if (good.size() < 3) {
        return r;
    }
    std::vector<cv::Point2f> src, dst;
    for (const auto &m : good) {
        src.push_back(probe->_kp[m.queryIdx].pt);
        dst.push_back(tmpl->_kp[m.trainIdx].pt);
    }
    cv::Mat inl;
    cv::Mat M = cv::estimateAffinePartial2D(src, dst, inl, cv::RANSAC, p.ransacPx * SCALE);
    if (M.empty()) {
        return r;
    }
    double s = std::hypot(M.at<double>(0, 0), M.at<double>(1, 0));
    double ang = std::atan2(M.at<double>(1, 0), M.at<double>(0, 0)) * 180.0 / M_PI;
    // A finger press does not noticeably scale; rotation stays within reason.
    if (!(0.85 < s && s < 1.18) || std::abs(ang) > p.maxRot) {
        return r;
    }
    int score = 0;
    for (size_t k = 0; k < good.size(); ++k) {
        if (inl.at<uint8_t>((int)k)) {
            score++;
            r->_pairs.push_back({good[k].queryIdx, good[k].trainIdx});
        }
    }
    r.score = score;
    r->_M = M;
    cv::Mat warped;
    cv::warpAffine(probe->_mask, warped, M, cv::Size(tmpl->_mask.cols, tmpl->_mask.rows));
    int area = std::max(1, cv::countNonZero(probe->_mask));
    r.overlap = (double)cv::countNonZero((warped > 0) & (tmpl->_mask > 0)) / area;
    if (r.score >= p.matchWeak) {
        r.ncc = alignedNcc(probe, tmpl, M);
    }
    r.accepted = (r.score >= p.matchScore && r.ncc >= p.matchStrongNcc) ||
                 (r.score >= p.matchWeak && r.ncc >= p.matchNcc);
    return r;
}

@implementation FPMatcher
+ (FPMatch *)match:(FPSample *)probe to:(FPSample *)tmpl params:(FPParams *)p {
    return matchSamples(probe, tmpl, p);
}

+ (FPMatch *)best:(FPSample *)probe in:(NSArray<FPSample *> *)samples params:(FPParams *)p
            index:(NSInteger *_Nullable)index {
    FPMatch *best = [FPMatch empty];
    NSInteger idx = -1;
    for (NSUInteger i = 0; i < samples.count; ++i) {
        FPMatch *m = matchSamples(probe, samples[i], p);
        if ([m isStrongerThan:best]) {
            best = m;
            idx = (NSInteger)i;
        }
    }
    if (index) {
        *index = idx;
    }
    return best;
}

+ (NSData *)drawMatch:(FPSample *)probe to:(FPSample *)tmpl match:(FPMatch *)m
                width:(NSInteger *)w height:(NSInteger *)h {
    cv::Mat a, b, ra, rb;
    cv::rotate(probe->_norm, ra, cv::ROTATE_90_COUNTERCLOCKWISE);
    cv::rotate(tmpl->_norm, rb, cv::ROTATE_90_COUNTERCLOCKWISE);
    cv::cvtColor(ra, a, cv::COLOR_GRAY2BGR);
    cv::cvtColor(rb, b, cv::COLOR_GRAY2BGR);
    const int gap = 12;
    cv::Mat canvas(a.rows + b.rows + gap, a.cols, CV_8UC3, cv::Scalar(255, 255, 255));
    a.copyTo(canvas.rowRange(0, a.rows));
    b.copyTo(canvas.rowRange(a.rows + gap, a.rows + gap + b.rows));
    int h0 = probe->_norm.cols, h1 = tmpl->_norm.cols;
    // (x, y) of the upright image -> after turning 90 degrees counter-clockwise
    auto rot = [](cv::Point2f pt, int width) {
        return cv::Point((int)pt.y, (int)(width - 1 - pt.x));
    };
    for (const auto &pr : m->_pairs) {
        cv::Point p0 = rot(probe->_kp[pr.first].pt, h0);
        cv::Point p1 = rot(tmpl->_kp[pr.second].pt, h1);
        p1.y += a.rows + gap;
        cv::line(canvas, p0, p1, cv::Scalar(40, 180, 40), 1, cv::LINE_AA);
        cv::circle(canvas, p0, 3, cv::Scalar(0, 120, 255), 1, cv::LINE_AA);
        cv::circle(canvas, p1, 3, cv::Scalar(0, 120, 255), 1, cv::LINE_AA);
    }
    return rgbaFromBgr(canvas, w, h);
}
@end

// ---------------------------------------------------------------------------------------
// mosaic.py

typedef cv::Matx33d Mat3;

static Mat3 homog(const cv::Mat &M) {  // 2 x 3 (any float type) -> 3 x 3 double
    cv::Mat m;
    M.convertTo(m, CV_64F);
    return Mat3(m.at<double>(0, 0), m.at<double>(0, 1), m.at<double>(0, 2),
                m.at<double>(1, 0), m.at<double>(1, 1), m.at<double>(1, 2), 0, 0, 1);
}

static cv::Mat top2(const Mat3 &m, int type) {
    cv::Mat out(2, 3, CV_64F);
    for (int r = 0; r < 2; ++r) {
        for (int c = 0; c < 3; ++c) {
            out.at<double>(r, c) = m(r, c);
        }
    }
    if (type != CV_64F) {
        out.convertTo(out, type);
    }
    return out;
}

struct MosaicEdge {
    int j, i;    // maps sample j's coordinates to sample i's
    double w;
    Mat3 M;
};

@interface FPMosaic () {
    FPParams *_p;
    std::vector<FPSample *> _samples;
    std::vector<MosaicEdge> _edges;  // in insertion order, as the Python dict
}
@end

@implementation FPMosaic
- (instancetype)initWithParams:(FPParams *)p {
    if ((self = [super init])) {
        _p = p;
    }
    return self;
}

- (NSInteger)count {
    return (NSInteger)_samples.size();
}

// ECC refinement; false when it fails or wanders off to another ridge period.
static bool refine(FPSample *s, FPSample *t, const cv::Mat &M, Mat3 *R, double *cc) {
    cv::Mat tpl(t->_norm.size(), CV_32F), inp;
    for (int r = 0; r < tpl.rows; ++r) {
        for (int c = 0; c < tpl.cols; ++c) {
            tpl.at<float>(r, c) = t->_mask.at<uint8_t>(r, c) > 0 ? t->_norm.at<uint8_t>(r, c) : 127;
        }
    }
    s->_norm.convertTo(inp, CV_32F);
    cv::Mat Wm = top2(homog(M).inv(), CV_32F);  // ECC maps template coordinates to input ones
    try {
        *cc = cv::findTransformECC(tpl, inp, Wm, cv::MOTION_EUCLIDEAN,
                                   cv::TermCriteria(cv::TermCriteria::EPS | cv::TermCriteria::COUNT,
                                                    60, 1e-4),
                                   s->_mask, 3);
    } catch (const cv::Exception &) {
        return false;
    }
    *R = homog(Wm).inv();
    if (std::hypot((*R)(0, 2) - M.at<double>(0, 2), (*R)(1, 2) - M.at<double>(1, 2)) > 4 * SCALE) {
        return false;
    }
    return true;
}

- (void)add:(FPSample *)s {
    int j = (int)_samples.size();
    for (int i = 0; i < j; ++i) {
        FPMatch *m = matchSamples(s, _samples[i], _p);
        if (!m.accepted) {
            continue;
        }
        Mat3 R;
        double cc = 0;
        if (!refine(s, _samples[i], m->_M, &R, &cc)) {
            R = homog(m->_M);
            cc = std::max(m.ncc, 0.0);
        }
        _edges.push_back({j, i, cc, R});
    }
    _samples.push_back(s);
}

- (std::vector<std::vector<int>>)islands {
    int n = (int)_samples.size();
    std::vector<int> comp(n);
    for (int k = 0; k < n; ++k) {
        comp[k] = k;
    }
    std::function<int(int)> find = [&](int a) {
        while (comp[a] != a) {
            comp[a] = comp[comp[a]];
            a = comp[a];
        }
        return a;
    };
    for (const auto &e : _edges) {
        comp[find(e.j)] = find(e.i);
    }
    std::vector<int> roots;
    std::map<int, std::vector<int>> groups;
    for (int k = 0; k < n; ++k) {
        int r = find(k);
        if (!groups.count(r)) {
            roots.push_back(r);
        }
        groups[r].push_back(k);
    }
    std::vector<std::vector<int>> out;
    for (int r : roots) {
        out.push_back(groups[r]);
    }
    std::stable_sort(out.begin(), out.end(), [](const auto &a, const auto &b) {
        if (a.size() != b.size()) {
            return a.size() > b.size();
        }
        return a[0] < b[0];
    });
    return out;
}

// Spanning tree from the best-connected sample; returns transforms in insertion order.
- (std::vector<std::pair<int, Mat3>>)layout:(const std::vector<int> &)island {
    std::map<int, double> weight;
    for (int k : island) {
        weight[k] = 0;
    }
    for (const auto &e : _edges) {
        if (weight.count(e.j)) {
            weight[e.j] += e.w;
            weight[e.i] += e.w;
        }
    }
    int start = island[0];
    for (int k : island) {
        if (weight[k] > weight[start] || (weight[k] == weight[start] && k < start)) {
            start = k;
        }
    }
    std::vector<std::pair<int, Mat3>> G{{start, Mat3::eye()}};
    auto has = [&](int k) {
        return std::any_of(G.begin(), G.end(), [&](const auto &g) { return g.first == k; });
    };
    auto get = [&](int k) {
        return std::find_if(G.begin(), G.end(), [&](const auto &g) { return g.first == k; })->second;
    };
    while (true) {
        const MosaicEdge *best = nullptr;
        for (const auto &e : _edges) {
            if (has(e.i) != has(e.j) && (!best || e.w > best->w)) {
                best = &e;
            }
        }
        if (!best) {
            return G;
        }
        if (has(best->i)) {
            G.push_back({best->j, get(best->i) * best->M});
        } else {
            G.push_back({best->i, get(best->j) * best->M.inv()});
        }
    }
}

- (cv::Mat)renderIsland:(const std::vector<int> &)island highlight:(int)highlight area:(double *)area {
    const int margin = 8;
    const float RIDGE[3] = {60, 56, 224}, NEW[3] = {40, 20, 255};
    const float PAPER[3] = {255, 255, 255}, EMPTY[3] = {236, 236, 236};
    auto G = [self layout:island];
    int h0 = _samples[island[0]]->_norm.rows, w0 = _samples[island[0]]->_norm.cols;
    cv::Matx<double, 3, 4> corners(0, w0, w0, 0, 0, 0, h0, h0, 1, 1, 1, 1);
    double x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
    for (const auto &g : G) {
        cv::Matx<double, 3, 4> pts = g.second * corners;
        for (int c = 0; c < 4; ++c) {
            x0 = std::min(x0, pts(0, c));
            x1 = std::max(x1, pts(0, c));
            y0 = std::min(y0, pts(1, c));
            y1 = std::max(y1, pts(1, c));
        }
    }
    x0 -= margin;
    y0 -= margin;
    x1 += margin;
    y1 += margin;
    int Wd = (int)std::ceil(x1 - x0), Hd = (int)std::ceil(y1 - y0);
    Mat3 T(1, 0, -x0, 0, 1, -y0, 0, 0, 1);
    cv::Mat inkSum = cv::Mat::zeros(Hd, Wd, CV_32F), wSum = cv::Mat::zeros(Hd, Wd, CV_32F);
    cv::Mat cover = cv::Mat::zeros(Hd, Wd, CV_32F), newW = cv::Mat::zeros(Hd, Wd, CV_32F);
    std::vector<cv::Point> quad;
    for (const auto &g : G) {
        FPSample *s = _samples[g.first];
        cv::Mat A = top2(T * g.second, CV_32F);
        cv::Mat ink;
        s->_norm.convertTo(ink, CV_32F);
        ink = 255.0f - ink;  // ridges (dark) carry the ink
        // Weight grows away from the covered area's edge; the 6th power approximates "the
        // innermost sample wins" while seams still blend a little.
        cv::Mat pm, dist, wgt;
        cv::resize(s->_pmask, pm, cv::Size(s->_norm.cols, s->_norm.rows), 0, 0, cv::INTER_NEAREST);
        cv::distanceTransform(pm, dist, cv::DIST_L2, 3);
        dist -= 2 * SCALE;
        wgt = dist / (6.0f * SCALE);
        wgt = cv::max(wgt, 0.0f);
        wgt = cv::min(wgt, 1.0f);
        cv::Mat wi, inkW, wp;
        cv::warpAffine(wgt, wi, A, cv::Size(Wd, Hd));
        cv::pow(wi, 6, wp);
        cv::warpAffine(ink, inkW, A, cv::Size(Wd, Hd));
        inkSum += inkW.mul(wp);
        wSum += wp;
        cover = cv::max(cover, wi);
        if (g.first == highlight) {
            newW = wi;
            cv::Matx<double, 3, 4> q = T * g.second * corners;
            for (int c = 0; c < 4; ++c) {
                quad.push_back(cv::Point((int)std::lround(q(0, c)), (int)std::lround(q(1, c))));
            }
        }
    }
    cv::Mat img(Hd, Wd, CV_8UC3);
    int covered = 0;
    for (int r = 0; r < Hd; ++r) {
        for (int c = 0; c < Wd; ++c) {
            float cv_ = cover.at<float>(r, c);
            uint8_t *px = img.ptr<uint8_t>(r, c);
            if (!(cv_ > 0.02f)) {
                for (int k = 0; k < 3; ++k) {
                    px[k] = (uint8_t)EMPTY[k];
                }
                continue;
            }
            covered++;
            float ws = wSum.at<float>(r, c);
            float ink = ws > 1e-12f ? inkSum.at<float>(r, c) / std::max(ws, 1e-12f) : 0.0f;
            float a = std::clamp((ink - 105.0f) / 55.0f, 0.0f, 1.0f);
            a = a * a * (3.0f - 2.0f * a);  // smoothstep: clean ridge edges
            float edge = std::clamp(cv_ / 0.3f, 0.0f, 1.0f);
            float nw = std::clamp(newW.at<float>(r, c), 0.0f, 1.0f);
            for (int k = 0; k < 3; ++k) {
                float ridge = RIDGE[k] + (NEW[k] - RIDGE[k]) * nw;
                float v = PAPER[k] * (1.0f - a) + ridge * a;
                v = EMPTY[k] + (v - EMPTY[k]) * edge;
                px[k] = (uint8_t)(int)v;
            }
        }
    }
    if (!quad.empty()) {
        std::vector<std::vector<cv::Point>> polys{quad};
        cv::polylines(img, polys, true, cv::Scalar(232, 115, 26), 2, cv::LINE_AA);
    }
    cv::Mat out;
    cv::rotate(img, out, cv::ROTATE_90_COUNTERCLOCKWISE);  // long side horizontal
    *area = covered / (PX_PER_MM * PX_PER_MM);
    return out;
}

- (NSData *)render:(NSInteger)highlight width:(NSInteger *)w height:(NSInteger *)h
              area:(double *)area islands:(NSArray<NSNumber *> **)islands
    highlightAlone:(BOOL *)alone {
    auto groups = [self islands];
    if (groups.empty()) {
        *area = 0;
        if (islands) {
            *islands = @[];
        }
        *alone = NO;
        return nil;
    }
    const int GAP = 16;
    std::vector<std::pair<cv::Mat, double>> tiles;
    for (size_t g = 0; g < groups.size(); ++g) {
        bool has = std::find(groups[g].begin(), groups[g].end(), (int)highlight) != groups[g].end();
        double a = 0;
        cv::Mat img = [self renderIsland:groups[g] highlight:has ? (int)highlight : -1 area:&a];
        if (g > 0) {  // smaller islands shrink and go underneath
            cv::Mat small;
            cv::resize(img, small, cv::Size(), 0.55, 0.55, cv::INTER_AREA);
            img = small;
        }
        tiles.push_back({img, a});
    }
    cv::Mat main = tiles[0].first;
    int width = 600;
    for (const auto &t : tiles) {
        width = std::max(width, t.first.cols);
    }
    std::vector<std::vector<cv::Mat>> rows;
    std::vector<cv::Mat> row;
    int rowW = 0;
    for (size_t k = 1; k < tiles.size(); ++k) {
        const cv::Mat &img = tiles[k].first;
        if (!row.empty() && rowW + img.cols > width) {
            rows.push_back(row);
            row.clear();
            rowW = 0;
        }
        row.push_back(img);
        rowW += img.cols + GAP;
    }
    if (!row.empty()) {
        rows.push_back(row);
    }
    int height = main.rows;
    for (const auto &r : rows) {
        int mh = 0;
        for (const auto &img : r) {
            mh = std::max(mh, img.rows);
        }
        height += mh + GAP;
    }
    cv::Mat canvas(height, width, CV_8UC3, cv::Scalar(236, 236, 236));
    main.copyTo(canvas(cv::Rect(0, 0, main.cols, main.rows)));
    int y = main.rows + GAP;
    for (const auto &r : rows) {
        int x = 0, mh = 0;
        for (const auto &img : r) {
            img.copyTo(canvas(cv::Rect(x, y, img.cols, img.rows)));
            x += img.cols + GAP;
            mh = std::max(mh, img.rows);
        }
        y += mh + GAP;
    }
    double total = 0;
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    for (size_t g = 0; g < groups.size(); ++g) {
        total += tiles[g].second;
        [sizes addObject:@(groups[g].size())];
    }
    *area = total;
    if (islands) {
        *islands = sizes;
    }
    bool aloneFound = false;
    for (const auto &g : groups) {
        if (g.size() == 1 && g[0] == (int)highlight) {
            aloneFound = true;
        }
    }
    *alone = highlight >= 0 && aloneFound && groups.size() > 1;
    return rgbaFromBgr(canvas, w, h);
}
@end
