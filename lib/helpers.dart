import 'dart:ui' show Rect;

import 'package:apple_vision_commons/apple_vision_commons.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Recognizes acceptable expiration date formats
/// In plain english the steps are:
///  1) The month:
///  a '0' followed by a number between '1' & '9 ' or just a number between '1' and '9'
///  <br>OR</br>
///  a '1' followed by a number between '0' & '2'
///  2) The slash:
///    a '/' (forward slash)
///  3) The year:
///    any combo of 2-4 numeric characters
final RegExp expDateFormat = RegExp(r'^((0?([1-9]))|1([0-2]))\/(\d{2,4})$');

/// Searches for an expiration date pattern *anywhere* within a larger string.
///
/// Unlike [expDateFormat] (which requires the whole string to be a date), this
/// finds `MM/YY` or `MM/YYYY` embedded in a longer OCR line such as
/// "VALID THRU 05/27". It tolerates optional whitespace around the slash, which
/// the text recognizer occasionally inserts (e.g. "05 / 27").
///
/// Group 1 captures the month (1-2 digits) and group 2 captures the year
/// (2-4 digits). The month range is validated downstream by the card validator.
final RegExp dateSearchFormat = RegExp(r'(\d{1,2})\s*[\/\-]\s*(\d{2,4})');

/// Searches for a credit-card-number candidate *anywhere* within a larger
/// string.
///
/// Unlike requiring the whole line to be the number, this finds a run of 13–19
/// digits embedded in a noisier OCR line such as "CARD 4111 1111 1111 1111". It
/// tolerates an arbitrary number of spaces or hyphens between digits (the text
/// recognizer is inconsistent about grouping, e.g. "4111  1111 1111-1111").
///
/// Letters, slashes and newlines break the run, so surrounding labels or an
/// adjacent expiry date on another line are not pulled in. Each match is still
/// Luhn/type validated downstream, so a spurious run that happens to be the
/// right length is rejected.
final RegExp cardNumberSearch = RegExp(r'\d(?:[ -]*\d){12,18}');

/// Matches a standalone run of exactly five digits delimited by whitespace or
/// the string boundaries (i.e. not adjacent to any other non-space character).
///
/// Used as a tolerant fallback for expiry dates where the recognizer reads the
/// "/" in `MM/YY` as a digit — almost always a 7 or a 1 — producing e.g.
/// "05727" or "05127" instead of "05/27". Restricting it to an isolated
/// whitespace-delimited 5-digit token keeps it from firing on card-number
/// groups or other embedded digits.
final RegExp isolatedFiveDigits = RegExp(r'(?<!\S)(\d{5})(?!\S)');

/// Recognizes all whitespace characters
final RegExp whiteSpaceRegex = RegExp(r'-|\s+\b|\b\s');

/// Parses the string form of the expiration date and returns the month and year
/// as a `List<String>`
///
/// Allows for the following date formats:
///     'MM/YY'
///     'MM/YYY'
///     'MM/YYYY'
///
/// This function will replace hyphens with slashes for dates that have hyphens in them
/// and remove any whitespace
List<String> parseDate(String expDateStr) {
  // Replace hyphens with slashes and remove whitespaces
  String formattedStr = expDateStr
      .replaceAll('-', '/')
      .replaceAll(whiteSpaceRegex, '');

  Match? match = expDateFormat.firstMatch(formattedStr);

  if (match == null) {
    return [];
  }

  return match[0]!.split('/');
}

/// Maps a camera sensor orientation (in degrees) to the Apple Vision
/// [ImageOrientation] expected by the iOS text recognizer.
///
/// This intentionally avoids any ML Kit types so the iOS build does not pull in
/// the ML Kit dependency. Android text recognition is handled natively through
/// the platform channel instead.
ImageOrientation appleOrientationFromSensor(int sensorOrientation) {
  switch (sensorOrientation) {
    case 180:
      return ImageOrientation.down;
    case 270:
      return ImageOrientation.downMirrored;
    case 0:
    case 90:
    default:
      return ImageOrientation.up;
  }
}

/// A rectangle of pixels (in image/sensor coordinates). All fields are even so
/// NV21 chroma stays aligned to 2x2 luma blocks when cropping.
class CropRect {
  final int x;
  final int y;
  final int width;
  final int height;

  const CropRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// Computes the scan-window crop rectangle for a camera frame and crops frames
/// down to it.
///
/// Running OCR on just the marked card region (plus [leeway]) instead of the
/// whole frame is faster and more accurate — text outside the card never
/// reaches the recognizer. The [widthFraction] / [heightFraction] are in
/// *display* space and MUST match the on-screen overlay; the cropper swaps them
/// into image space based on the sensor orientation.
class ScanWindowCropper {
  /// Width of the scan window as a fraction of the (display) frame.
  final double widthFraction;

  /// Height of the scan window as a fraction of the (display) frame.
  final double heightFraction;

  /// Vertical position of the scan window's *center*, as a fraction down the
  /// display (0.0 = top edge, 0.5 = middle, 1.0 = bottom edge). The overlay
  /// cutout, the Android crop and the iOS region-of-interest are all placed to
  /// match this.
  final double centerOffsetY;

  /// Extra margin added around the scan window before cropping, as a fraction
  /// of its size (0.2 = 20% larger). Gives the user a little leeway so a
  /// slightly misplaced card is still captured.
  final double leeway;

  const ScanWindowCropper({
    this.widthFraction = 0.95,
    this.heightFraction = 0.3,
    this.centerOffsetY = 0.5,
    this.leeway = 0.2,
  });

  /// The pixel rectangle of a frame (in sensor/image coordinates) corresponding
  /// to the on-screen scan window, expanded by [leeway].
  ///
  /// The frame is rotated by [sensorOrientation] for display, so for a 90°/270°
  /// sensor the display width maps to the image height and vice-versa; the
  /// fractions are swapped accordingly. The window is horizontally centered and
  /// positioned vertically by [centerOffsetY]; all coordinates are forced even
  /// for NV21 alignment.
  CropRect rectFor(int imageWidth, int imageHeight, int sensorOrientation) {
    final double wFrac = (widthFraction * (1 + leeway)).clamp(0.0, 1.0);
    final double hFrac = (heightFraction * (1 + leeway)).clamp(0.0, 1.0);

    final bool swap = sensorOrientation == 90 || sensorOrientation == 270;
    final double imgWFrac = swap ? hFrac : wFrac;
    final double imgHFrac = swap ? wFrac : hFrac;

    int cropW = (imageWidth * imgWFrac).round();
    int cropH = (imageHeight * imgHFrac).round();
    cropW -= cropW % 2;
    cropH -= cropH % 2;

    // The display's vertical axis maps to the image's X axis when the frame is
    // rotated 90°/270° for display, and to the Y axis otherwise. The direction
    // also reverses for 270°/180°. Translate [centerOffsetY] (a fraction down
    // the display) into a center fraction along whichever image axis it lands
    // on; the other axis stays centered.
    final bool flip = sensorOrientation == 270 || sensorOrientation == 180;
    final double centerFrac = flip ? 1 - centerOffsetY : centerOffsetY;

    int cropX;
    int cropY;
    if (swap) {
      cropX = (imageWidth * centerFrac - cropW / 2).round();
      cropY = (imageHeight - cropH) ~/ 2;
    } else {
      cropX = (imageWidth - cropW) ~/ 2;
      cropY = (imageHeight * centerFrac - cropH / 2).round();
    }

    // Keep the (possibly offset) window inside the frame, then force even
    // coordinates so the interleaved V,U chroma stays aligned to 2x2 luma.
    cropX = cropX.clamp(0, imageWidth - cropW);
    cropY = cropY.clamp(0, imageHeight - cropH);
    cropX -= cropX % 2;
    cropY -= cropY % 2;

    return CropRect(x: cropX, y: cropY, width: cropW, height: cropH);
  }

  /// The scan window as a normalized [Rect] (0..1) for Apple Vision's
  /// `regionOfInterest`, restricting recognition without cropping the buffer.
  ///
  /// Horizontally centered, positioned vertically by [centerOffsetY] and
  /// expanded by [leeway]. Vision applies the region in the upright (oriented)
  /// image space using a **lower-left** origin, so the window centered
  /// [centerOffsetY] down from the top sits `1 - centerOffsetY` up from the
  /// bottom; the rect's bottom edge is half its height below that.
  Rect visionRegionOfInterest() {
    final double w = (widthFraction * (1 + leeway)).clamp(0.0, 1.0);
    final double h = (heightFraction * (1 + leeway)).clamp(0.0, 1.0);
    final double left = ((1 - w) / 2).clamp(0.0, 1.0 - w);
    final double bottom = (1 - centerOffsetY - h / 2).clamp(0.0, 1.0 - h);
    return Rect.fromLTWH(left, bottom, w, h);
  }

  /// Crops [image] to [rect] on a background isolate, returning a tightly packed
  /// buffer in the frame's own pixel format (`rect.width x rect.height`).
  ///
  /// This is the single crop entry point for both platforms; it dispatches on
  /// the frame's format because the byte layouts differ (BGRA8888 on iOS is one
  /// 4-bytes-per-pixel plane; Android delivers NV21 / multi-plane YUV_420_888).
  Future<Uint8List> crop(CameraImage image, CropRect rect) {
    if (image.format.group == ImageFormatGroup.bgra8888) {
      return compute(
        _cropBgra,
        _BgraCropRequest(
          srcBytes: image.planes.first.bytes,
          srcRowStride: image.planes.first.bytesPerRow,
          crop: rect,
        ),
      );
    }

    // Single-plane frames are already NV21; pass them through as the full
    // buffer and let the isolate do only the crop.
    if (image.planes.length < 3) {
      return compute(
        _cropYuv,
        _Nv21Frame(
          width: image.width,
          height: image.height,
          singlePlaneBytes: image.planes.first.bytes,
          crop: rect,
        ),
      );
    }

    return compute(
      _cropYuv,
      _Nv21Frame(
        width: image.width,
        height: image.height,
        yBytes: image.planes[0].bytes,
        uBytes: image.planes[1].bytes,
        vBytes: image.planes[2].bytes,
        yRowStride: image.planes[0].bytesPerRow,
        uRowStride: image.planes[1].bytesPerRow,
        vRowStride: image.planes[2].bytesPerRow,
        uPixelStride: image.planes[1].bytesPerPixel ?? 2,
        vPixelStride: image.planes[2].bytesPerPixel ?? 2,
        crop: rect,
      ),
    );
  }

  // --- background-isolate workers (static so they can be passed to compute) ---

  /// Crops a single-plane BGRA8888 buffer to its [CropRect], returning a new
  /// tightly packed BGRA buffer (`width * height * 4` bytes).
  static Uint8List _cropBgra(_BgraCropRequest req) {
    const int bpp = 4;
    final CropRect crop = req.crop;
    final int rowBytes = crop.width * bpp;
    final Uint8List out = Uint8List(rowBytes * crop.height);

    int dst = 0;
    for (int row = 0; row < crop.height; row++) {
      final int start = (crop.y + row) * req.srcRowStride + crop.x * bpp;
      out.setRange(dst, dst + rowBytes, req.srcBytes, start);
      dst += rowBytes;
    }

    return out;
  }

  /// Produces a tightly packed NV21 buffer cropped to [_Nv21Frame.crop],
  /// rebuilding a full NV21 buffer first for multi-plane YUV_420_888 input.
  static Uint8List _cropYuv(_Nv21Frame frame) {
    final Uint8List full = frame.singlePlaneBytes ?? _buildFullNv21(frame);
    return _cropNv21(full, frame.width, frame.height, frame.crop);
  }

  /// Rebuilds a packed full-frame NV21 buffer (full Y plane then interleaved
  /// V,U chroma) from the multi-plane YUV_420_888 data in [frame].
  ///
  /// Many Android devices ignore the requested NV21 stream and deliver
  /// multi-plane YUV_420_888; feeding those planes to ML Kit as if they were
  /// NV21 yields the wrong layout (planar rather than interleaved V/U). This
  /// honours each plane's row/pixel strides so it works for both planar and
  /// semi-planar device layouts.
  static Uint8List _buildFullNv21(_Nv21Frame frame) {
    final int width = frame.width;
    final int height = frame.height;
    final int ySize = width * height;
    final Uint8List nv21 = Uint8List(ySize + ySize ~/ 2);

    final Uint8List yBytes = frame.yBytes!;
    final Uint8List uBytes = frame.uBytes!;
    final Uint8List vBytes = frame.vBytes!;

    // Y plane — copy row by row, dropping any row-stride padding.
    int dst = 0;
    if (frame.yRowStride == width) {
      nv21.setRange(0, ySize, yBytes);
      dst = ySize;
    } else {
      for (int row = 0; row < height; row++) {
        final int start = row * frame.yRowStride;
        nv21.setRange(dst, dst + width, yBytes, start);
        dst += width;
      }
    }

    // Chroma — interleave as V, U (NV21 order), honouring row/pixel strides.
    final int chromaHeight = height ~/ 2;
    final int chromaWidth = width ~/ 2;

    for (int row = 0; row < chromaHeight; row++) {
      int uIndex = row * frame.uRowStride;
      int vIndex = row * frame.vRowStride;
      for (int col = 0; col < chromaWidth; col++) {
        // Guard the last sample: on semi-planar layouts the V/U planes can be a
        // byte short, which would otherwise throw a RangeError.
        nv21[dst++] = vIndex < vBytes.length ? vBytes[vIndex] : 0;
        nv21[dst++] = uIndex < uBytes.length ? uBytes[uIndex] : 0;
        uIndex += frame.uPixelStride;
        vIndex += frame.vPixelStride;
      }
    }

    return nv21;
  }

  /// Crops a packed full-frame NV21 buffer to [crop], returning a new packed
  /// NV21 buffer of `crop.width x crop.height`. The crop must have even
  /// coordinates so the interleaved V,U chroma stays aligned to 2x2 luma blocks.
  static Uint8List _cropNv21(
    Uint8List src,
    int width,
    int height,
    CropRect crop,
  ) {
    final int cw = crop.width;
    final int ch = crop.height;
    final Uint8List out = Uint8List(cw * ch + cw * ch ~/ 2);

    int dst = 0;

    // Y plane.
    for (int row = 0; row < ch; row++) {
      final int start = (crop.y + row) * width + crop.x;
      out.setRange(dst, dst + cw, src, start);
      dst += cw;
    }

    // Interleaved V,U plane: one chroma row per two luma rows, same byte width.
    final int chromaBase = width * height;
    for (int row = 0; row < ch ~/ 2; row++) {
      final int start = chromaBase + (crop.y ~/ 2 + row) * width + crop.x;
      out.setRange(dst, dst + cw, src, start);
      dst += cw;
    }

    return out;
  }
}

/// One frame's pixel data plus the [crop] to apply, sent across an isolate
/// boundary (a [CameraImage] itself is not sendable).
///
/// For Android NV21 single-plane frames, [singlePlaneBytes] holds the already
/// laid-out NV21 buffer. For multi-plane YUV_420_888 frames, the Y/U/V plane
/// bytes and strides are supplied and a real NV21 buffer is rebuilt first.
class _Nv21Frame {
  final int width;
  final int height;
  final CropRect crop;
  final Uint8List? singlePlaneBytes;
  final Uint8List? yBytes;
  final Uint8List? uBytes;
  final Uint8List? vBytes;
  final int yRowStride;
  final int uRowStride;
  final int vRowStride;
  final int uPixelStride;
  final int vPixelStride;

  const _Nv21Frame({
    required this.width,
    required this.height,
    required this.crop,
    this.singlePlaneBytes,
    this.yBytes,
    this.uBytes,
    this.vBytes,
    this.yRowStride = 0,
    this.uRowStride = 0,
    this.vRowStride = 0,
    this.uPixelStride = 2,
    this.vPixelStride = 2,
  });
}

/// A single-plane BGRA8888 frame plus the crop to apply, sent to the background
/// isolate that crops it.
class _BgraCropRequest {
  final Uint8List srcBytes;
  final int srcRowStride;
  final CropRect crop;

  const _BgraCropRequest({
    required this.srcBytes,
    required this.srcRowStride,
    required this.crop,
  });
}
