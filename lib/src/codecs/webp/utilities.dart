part of '../webp.dart';

/// Converts an unsigned byte to its signed two's-complement value.
int _unsignedByteToSigned(int value) => value.toSigned(8);

/// Converts a signed integer to its unsigned 32-bit representation.
int _signedInt32ToUnsigned(int value) => value & 0xffffffff;

/// Performs a signed 32-bit right shift.
int _signedShiftRight(int value, int count) => value.toSigned(32) >> count;

/// Packs four channels in the little-endian order used by VP8L internals.
int _rgbaToUint32(int red, int green, int blue, int alpha) => (red & 0xff) | ((green & 0xff) << 8) | ((blue & 0xff) << 16) | ((alpha & 0xff) << 24);

/// Extracts the least-significant packed channel.
int _uint32ToRed(int color) => color & 0xff;

/// Extracts the second packed channel.
int _uint32ToGreen(int color) => (color >>> 8) & 0xff;

/// Extracts the third packed channel.
int _uint32ToBlue(int color) => (color >>> 16) & 0xff;

/// Extracts the most-significant packed channel.
int _uint32ToAlpha(int color) => (color >>> 24) & 0xff;
