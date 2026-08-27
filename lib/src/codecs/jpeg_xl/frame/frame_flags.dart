/// Frame type, encoding, flag, and blend-mode constants (spec values).
abstract final class FrameFlags {
  /// Frame-type identifier for regular frame.
  static const regularFrame = 0;

  /// Bit flag enabling low frequency frame.
  static const lowFrequencyFrame = 1;

  /// Frame-type identifier for reference only.
  static const referenceOnly = 2;

  /// Frame-type identifier for skip progressive.
  static const skipProgressive = 3;

  /// Encoding identifier for vardct.
  static const vardct = 0;

  /// Encoding identifier for modular.
  static const modular = 1;

  /// Bit flag enabling noise.
  static const int noise = 1 << 0;

  /// Bit flag enabling patches.
  static const int patches = 1 << 1;

  /// Bit flag enabling splines.
  static const int splines = 1 << 4;

  /// Whether decoding uses a separate low-frequency frame.
  static const int useLfFrame = 1 << 5;

  /// Bit flag enabling skip adaptive low-frequency smoothing.
  static const int skipAdaptiveLfSmoothing = 1 << 7;

  /// Blending-mode identifier for replace.
  static const blendReplace = 0;

  /// Blending-mode identifier for add.
    static const blendAdd = 1;

  /// Blending-mode identifier for blend.
    static const blendBlend = 2;

  /// Blending-mode identifier for mul add.
    static const blendMulAdd = 3;

  /// Blending-mode identifier for multiply.
    static const blendMultiply = 4;
}
