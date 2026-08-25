/// Frame type, encoding, flag, and blend-mode constants (spec values).
abstract final class FrameFlags {
  /// Stores the regular frame value used while processing JPEG XL data.
  ///
  static const regularFrame = 0;

  /// Stores the lf frame value used while processing JPEG XL data.
  ///
  static const lfFrame = 1;

  /// Stores the reference only value used while processing JPEG XL data.
  ///
  static const referenceOnly = 2;

  /// Stores the skip progressive value used while processing JPEG XL data.
  ///
  static const skipProgressive = 3;

  /// Stores the vardct value used while processing JPEG XL data.
  ///
  static const vardct = 0;

  /// Stores the modular value used while processing JPEG XL data.
  ///
  static const modular = 1;

  /// Stores the noise value used while processing JPEG XL data.
  ///
  static const int noise = 1 << 0;

  /// Stores the patches value used while processing JPEG XL data.
  ///
  static const int patches = 1 << 1;

  /// Stores the splines value used while processing JPEG XL data.
  ///
  static const int splines = 1 << 4;

  /// Stores the use lf frame value used while processing JPEG XL data.
  ///
  static const int useLfFrame = 1 << 5;

  /// Stores the skip adaptive lf smoothing value used while processing JPEG XL data.
  ///
  static const int skipAdaptiveLfSmoothing = 1 << 7;

  /// Stores the blend replace value used while processing JPEG XL data.
  ///
  static const blendReplace = 0;

  /// Stores the blend add value used while processing JPEG XL data.
  ///
  static const blendAdd = 1;

  /// Stores the blend blend value used while processing JPEG XL data.
  ///
  static const blendBlend = 2;

  /// Stores the blend mul add value used while processing JPEG XL data.
  ///
  static const blendMulAdd = 3;

  /// Stores the blend mult value used while processing JPEG XL data.
  ///
  static const blendMult = 4;
}
