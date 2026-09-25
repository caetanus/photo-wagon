/// Face-embedding constants shared by the vision code (detect.d, OpenCV) and the storage
/// that every build carries (repo.d) — kept apart so a no-vision build (the `node` hub) can
/// store and read faces without linking the detector.
module photowagon.core.faces.dims;

/// Length of an r100/SFace-space face embedding (float32 values).
enum faceDim = 512;
