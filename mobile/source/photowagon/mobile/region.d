/// The visible part of a zoomed photo, decoded from the original at the resolution the screen
/// can show — the original's own when zoomed in enough — and nothing else of the file.
///
/// The region comes as fractions of the picture AS SHOWN (EXIF-rotated). QImageReader crops
/// in the file's STORED orientation and rotates afterwards (autoTransform), so the region is
/// mapped back through the inverse of the file's transformation first.
module photowagon.mobile.region;

import qt.quick.qimagereader;
import qt.quick.qimage;
import qt.quick.qsize;
import qt.quick.qrect;

/// A rectangle in fractions of a picture: x, y, w, h in 0..1.
struct Frac
{
    double x = 0, y = 0, w = 1, h = 1;
}

// QImageIOHandler::Transformation
private enum : int { mirror = 1, flip = 2, rotate90 = 4, rotate270 = 7 }

/// Where a point of the STORED picture lands in the one shown, for `orient` — what Qt's
/// qt_imageTransform does: Rotate270 alone, else mirror/flip then a clockwise 90°.
private void forward(int orient, double u, double v, out double su, out double sv)
{
    if (orient == rotate270)
    {
        su = v;
        sv = 1 - u;
        return;
    }
    if (orient & mirror)
        u = 1 - u;
    if (orient & flip)
        v = 1 - v;
    if (orient & rotate90)
    {
        immutable t = u;
        u = 1 - v;
        v = t;
    }
    su = u;
    sv = v;
}

/// The inverse of `forward`: a point of the picture as shown → the stored picture.
private void inverse(int orient, double u, double v, out double su, out double sv)
{
    if (orient == rotate270)
    {
        su = 1 - v;
        sv = u;
        return;
    }
    if (orient & rotate90)
    {
        immutable t = u;
        u = v;
        v = 1 - t;
    }
    if (orient & flip)
        v = 1 - v;
    if (orient & mirror)
        u = 1 - u;
    su = u;
    sv = v;
}

/// The shown region `r` as a region of the stored picture.
Frac toStored(int orient, Frac r)
{
    import std.algorithm : min, max;

    double x0 = 1, y0 = 1, x1 = 0, y1 = 0;
    foreach (c; [[r.x, r.y], [r.x + r.w, r.y], [r.x, r.y + r.h], [r.x + r.w, r.y + r.h]])
    {
        double u, v;
        inverse(orient, c[0], c[1], u, v);
        x0 = min(x0, u); y0 = min(y0, v);
        x1 = max(x1, u); y1 = max(y1, v);
    }
    return Frac(x0, y0, x1 - x0, y1 - y0);
}

/// Decodes region `r` (fractions of the picture as shown) of `src` into `img`, rotated as
/// shown, its long side at most `maxEdge` — the screen pixels it covers; past that more
/// resolution would not show — and at the original's resolution otherwise. Only that part is
/// kept (the JPEG reader crops as it decodes). Qt thread only (see phoneindex.d).
void decodeRegion(QImageReader reader, QImage img, string src, Frac r, int maxEdge)
{
    import std.algorithm : min, max;
    import std.math : floor, ceil;

    reader.setFileName(src);
    reader.setAutoTransform(true);
    auto raw = reader.size();   // the stored size, before the transformation
    immutable W = raw.width, H = raw.height;
    if (W <= 0 || H <= 0)
        throw new Exception("region: cannot read the image header");
    r.x = max(0.0, min(1.0, r.x)); r.y = max(0.0, min(1.0, r.y));
    r.w = max(0.0, min(1.0 - r.x, r.w)); r.h = max(0.0, min(1.0 - r.y, r.h));
    if (r.w <= 0 || r.h <= 0)
        throw new Exception("region: empty");
    auto s = toStored(reader.transformation(), r);
    // at full resolution the crop is this many stored pixels
    int cx = cast(int) floor(s.x * W), cy = cast(int) floor(s.y * H);
    int cw = cast(int) ceil((s.x + s.w) * W) - cx, ch = cast(int) ceil((s.y + s.h) * H) - cy;
    cw = max(1, min(W - cx, cw));
    ch = max(1, min(H - cy, ch));
    immutable f = maxEdge > 0 && max(cw, ch) > maxEdge ? cast(double) maxEdge / max(cw, ch) : 1.0;
    if (f < 1)
    {
        // read the whole picture scaled (DCT-scaled for a JPEG: cheap) and crop in that scale
        auto whole = QSize.__make(max(1, cast(int)(W * f)), max(1, cast(int)(H * f)));
        reader.setScaledSize(whole);
        auto clip = QRect.__make(cast(int)(cx * f), cast(int)(cy * f), max(1, cast(int)(cw * f)), max(1, cast(int)(ch * f)));
        reader.setScaledClipRect(clip);
    }
    else
    {
        auto clip = QRect.__make(cx, cy, cw, ch);
        reader.setClipRect(clip);
    }
    // read() returning QImage by value is mis-bound (sret); the pointer overload is safe
    if (!reader.read(cast(QImage*) img.ptr()) || img.isNull())
        throw new Exception("region: decode failed");
}

unittest
{
    import std.math : isClose;

    // every transformation: the inverse undoes the forward map
    foreach (o; [0, 1, 2, 3, 4, 5, 6, 7])
        foreach (p; [[0.0, 0.0], [1.0, 0.0], [0.25, 0.75], [0.6, 0.1]])
        {
            double u, v, a, b;
            forward(o, p[0], p[1], u, v);
            inverse(o, u, v, a, b);
            assert(isClose(a, p[0]) && isClose(b, p[1]));
        }
    // a clockwise-rotated phone photo (EXIF 6 = Rotate90): the TOP strip as shown is the
    // stored picture's LEFT strip
    auto s = toStored(4, Frac(0, 0, 1, 0.25));
    assert(isClose(s.x, 0) && isClose(s.y, 0) && isClose(s.w, 0.25) && isClose(s.h, 1));
    // no transformation: the region as it is
    auto n = toStored(0, Frac(0.1, 0.2, 0.3, 0.4));
    assert(isClose(n.x, 0.1) && isClose(n.y, 0.2) && isClose(n.w, 0.3) && isClose(n.h, 0.4));
}
