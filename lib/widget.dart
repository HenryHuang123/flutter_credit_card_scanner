import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:apple_vision_recognize_text/apple_vision_recognize_text.dart'
    as apple;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'clipper.dart';
import 'credit_card.dart';
import 'helpers.dart';
import 'process.dart';

/// A widget that displays a live camera preview and scans for credit card information.
///
/// This widget uses the device's camera to capture images and performs optical character
/// recognition (OCR) to extract text from the images. It then analyzes the extracted
/// text to identify credit card numbers, cardholder names, and expiry dates.
///
/// The widget provides callbacks for successful scans and errors, allowing developers
/// to handle scanned credit card data and display appropriate UI feedback.
///
/// To use the widget, simply create an instance of [CameraScannerWidget] and provide
/// the required callbacks:
///
/// ```dart
/// CameraScannerWidget(
///   onScan: (context, creditCardModel) {
///     // Handle the scanned credit card data here
///   },
///   loadingHolder: Center(child: CircularProgressIndicator()),
///   onNoCamera: () {
///     // Handle the case where no camera is available
///   },
/// )
/// ```
///
/// The [onScan] callback is triggered when a credit card is successfully scanned,
/// providing a [CreditCardModel] object containing the extracted card information.
///
/// The [loadingHolder] widget is displayed while the camera is initializing.
///
/// The [onNoCamera] callback is triggered if no camera is available on the device.
class CameraScannerWidget extends StatefulWidget {
  /// Callback function called when a credit card is successfully scanned.
  final void Function(BuildContext, CreditCardModel?) onScan;

  /// Widget to display while the camera is initializing.
  final Widget loadingHolder;

  /// Callback function called when no camera is available on the device.
  final void Function() onNoCamera;

  /// Aspect ratio for the camera preview. If null, uses the device's screen aspect ratio.
  final double? aspectRatio;

  /// Whether to scan for the card number. Defaults to true.
  final bool cardNumber;

  /// Whether to scan for the card holder's name. Defaults to true.
  final bool cardHolder;

  /// Whether to scan for the card's expiry date. Defaults to true.
  final bool cardExpiryDate;

  /// The color of the overlay that highlights the credit card scanning area.
  final Color? colorOverlay;

  /// The shape of the border surrounding the credit card scanning area.
  final ShapeBorder? shapeBorder;

  /// this will force validation of the card number means it will apply luhn algorithm to the card number
  final bool useLuhnValidation;

  final bool debug;

  /// the duration of the next frame
  ///
  /// this can be used to slow down the camera scanning and process the image
  /// so it will scan and wait for the next frame to be processed based on the duration
  ///
  /// default is null which means the camera will scan as fast as possible
  final Duration? durationOfNextFrame;

  /// The resolution preset for the camera. Defaults to [ResolutionPreset.high].
  ///
  /// This can be used to set the resolution of the camera to a lower resolution to improve performance.
  ///
  /// depands on the targetted platfrom it can be ResolutionPreset.low, ResolutionPreset.medium, ResolutionPreset.high, ResolutionPreset.veryHigh, ResolutionPreset.ultraHigh, ResolutionPreset.max
  final ResolutionPreset? resolutionPreset;

  /// Creates a [CameraScannerWidget].
  ///
  /// The [onScan], [loadingHolder], and [onNoCamera] parameters are required.
  const CameraScannerWidget({
    super.key,
    required this.onScan,
    required this.loadingHolder,
    required this.onNoCamera,
    this.aspectRatio,
    this.cardNumber = true,
    this.cardHolder = true,
    this.cardExpiryDate = true,
    this.colorOverlay,
    this.shapeBorder,
    this.useLuhnValidation = true,
    this.debug = kDebugMode,
    this.durationOfNextFrame,
    this.resolutionPreset,
  });

  @override
  State<CameraScannerWidget> createState() => _CameraScannerWidgetState();
}

class _CameraScannerWidgetState extends State<CameraScannerWidget>
    with WidgetsBindingObserver {
  /// Platform channel used to run Android text recognition natively (ML Kit).
  ///
  /// ML Kit is only wired up on the Android side of the plugin, so it is never
  /// installed on iOS, where Apple Vision is used instead.
  static const MethodChannel _channel = MethodChannel(
    'flutter_credit_card_scanner',
  );

  final appleVisionController = apple.AppleVisionRecognizeTextController();

  /// The camera controller used to manage the device's camera.
  CameraController? controller;

  /// Notifier to manage the loading state of the camera.
  final valueLoading = ValueNotifier<bool>(true);

  /// Flag to prevent multiple simultaneous scans.
  bool scanning = false;

  late final _process = ProccessCreditCard(
    useLuhnValidation: widget.useLuhnValidation,
    checkCreditCardNumber: widget.cardNumber,
    checkCreditCardName: widget.cardHolder,
    checkCreditCardExpiryDate: widget.cardExpiryDate,
  );
  Color get colorOverlay =>
      widget.colorOverlay ?? Colors.black.withValues(alpha: 0.8);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return ValueListenableBuilder(
      valueListenable: valueLoading,
      builder: (context, isLoading, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: isLoading
              ? widget.loadingHolder
              : Stack(
                  children: [
                    // Camera
                    // AspectRatio(
                    //     aspectRatio: MediaQuery.of(context).size.aspectRatio,
                    //     child: CameraPreview(controller!)),

                    // Overlay
                    Container(
                      width: size.width,
                      height: size.height,
                      color: Colors.black,
                    ),
                    Center(child: CameraPreview(controller!)),

                    Container(
                      decoration: ShapeDecoration(
                        shape:
                            widget.shapeBorder ??
                            OverlayShape(
                              cutOutHeight: size.height * 0.3,
                              cutOutWidth: size.width * 0.95,
                              overlayColor: colorOverlay,
                              borderRadius: 20,
                            ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (controller != null) {
      controller!.dispose();
    }

    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    availableCameras()
        .then((v) async {
          if (v.isEmpty) {
            if (mounted) {
              widget.onNoCamera();
            }
            return;
          }

          final c = v.firstWhere(
            (element) => element.lensDirection == CameraLensDirection.back,
          );

          _initializeCameraController(c);
        })
        .onError((error, stackTrace) {
          if (kDebugMode) {
            log(error.toString());
            log(stackTrace.toString());
          }
          if (mounted) {
            widget.onNoCamera();
          }
        });
  }

  /// Processes the recognized text lines to extract credit card information.
  ///
  /// Both recognizers — Apple Vision on iOS and ML Kit (native, via the platform
  /// channel) on Android — produce a list of text lines that are fed through the
  /// same extraction pipeline.
  void onScanLines(List<String> lines) {
    for (final line in lines) {
      if (widget.debug) log(line);

      _process.processNumber(line);
      _process.processName(line);
      _process.processDate(line);
    }

    // ML Kit (and Apple Vision) frequently break a single card number or expiry
    // date into several separate lines. Re-run number/date detection over the
    // combined text so fragments such as "4111 1111" + "1111 1111" can be
    // reassembled. Letters break a digit run and each candidate is still
    // Luhn-validated, so joining the name/date lines in does not produce false
    // positives. Only attempt this when the per-line pass came up empty so a
    // value already found in isolation is never clobbered.
    if (_process.cardNumber.isEmpty || _process.cardExpirationMonth.isEmpty) {
      final joined = lines.join(' ');
      if (_process.cardNumber.isEmpty) _process.processNumber(joined);
      if (_process.cardExpirationMonth.isEmpty) _process.processDate(joined);
    }

    final creditCardModel = _process.getCreditCardModel();

    if (creditCardModel != null) {
      if (widget.debug) {
        log("Scanning catched card: $creditCardModel");
      }
      if (mounted) widget.onScan(context, creditCardModel);
    }
  }

  /// Converts a [CameraImage] into a tightly packed NV21 byte buffer for ML Kit.
  ///
  /// The camera stream is requested as NV21, but many Android devices ignore
  /// that and deliver multi-plane YUV_420_888 instead. Passing those planes to
  /// ML Kit as if they were NV21 (the previous behaviour) yields a buffer of
  /// roughly the right size but the wrong layout — planar YUV rather than NV21's
  /// interleaved V/U — which is why text was read but almost always wrong.
  ///
  /// This rebuilds a real NV21 buffer: the full Y (luminance) plane followed by
  /// interleaved V,U chroma, honouring each plane's row and pixel strides so it
  /// works for both planar and semi-planar device layouts.
  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    // Single-plane frames are already NV21 (the format we asked for); the
    // native side strips any row padding, so hand the bytes over unchanged.
    if (image.planes.length < 3) {
      return image.planes.first.bytes;
    }

    final int ySize = width * height;
    final Uint8List nv21 = Uint8List(ySize + ySize ~/ 2);

    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    // Y plane — copy row by row, dropping any row-stride padding.
    int dst = 0;
    final int yRowStride = yPlane.bytesPerRow;
    if (yRowStride == width) {
      nv21.setRange(0, ySize, yPlane.bytes);
      dst = ySize;
    } else {
      final Uint8List yBytes = yPlane.bytes;
      for (int row = 0; row < height; row++) {
        final int start = row * yRowStride;
        nv21.setRange(dst, dst + width, yBytes, start);
        dst += width;
      }
    }

    // Chroma — interleave as V, U (NV21 order), honouring row/pixel strides.
    final Uint8List uBytes = uPlane.bytes;
    final Uint8List vBytes = vPlane.bytes;
    final int uRowStride = uPlane.bytesPerRow;
    final int vRowStride = vPlane.bytesPerRow;
    final int uPixelStride = uPlane.bytesPerPixel ?? 2;
    final int vPixelStride = vPlane.bytesPerPixel ?? 2;
    final int chromaHeight = height ~/ 2;
    final int chromaWidth = width ~/ 2;

    for (int row = 0; row < chromaHeight; row++) {
      int uIndex = row * uRowStride;
      int vIndex = row * vRowStride;
      for (int col = 0; col < chromaWidth; col++) {
        // Guard the last sample: on semi-planar layouts the V/U planes can be a
        // byte short, which would otherwise throw a RangeError.
        nv21[dst++] = vIndex < vBytes.length ? vBytes[vIndex] : 0;
        nv21[dst++] = uIndex < uBytes.length ? uBytes[uIndex] : 0;
        uIndex += uPixelStride;
        vIndex += vPixelStride;
      }
    }

    return nv21;
  }

  void process(CameraImage image, CameraDescription description) async {
    if (scanning) return;

    scanning = true;

    if (widget.debug) {
      // Surface the real frame layout. If `planes` is 3 the device handed back
      // multi-plane YUV_420_888 rather than the single-plane NV21 we requested,
      // which is why feeding the raw bytes to ML Kit produced garbage.
      final expectedNv21 = (image.width * image.height * 3) ~/ 2;
      log(
        'frame format check: group=${image.format.group} '
        'planes=${image.planes.length} '
        'planeBytes=${image.planes.map((p) => p.bytes.length).toList()} '
        'expectedNV21=$expectedNv21 width=${image.width} '
        'height=${image.height} '
        'rowStrides=${image.planes.map((p) => p.bytesPerRow).toList()} '
        'pixelStrides=${image.planes.map((p) => p.bytesPerPixel).toList()}',
      );
    }

    try {
      if (Platform.isIOS) {
        // BGRA8888 on iOS is single-plane.
        final Uint8List bytes = image.planes.first.bytes;
        final textR = await appleVisionController.processImage(
          apple.RecognizeTextData(
            automaticallyDetectsLanguage: false,
            languages: [const Locale('en', 'US')],
            recognitionLevel: apple.RecognitionLevel.accurate,
            image: bytes,
            orientation: appleOrientationFromSensor(
              description.sensorOrientation,
            ),
            imageSize: Size(image.width.toDouble(), image.height.toDouble()),
          ),
        );

        if (textR?.isNotEmpty == true) {
          final lines = <String>[
            for (final item in textR!) ...item.listText,
          ];
          onScanLines(lines);
        }
      } else {
        // Android: run ML Kit text recognition natively through the plugin.
        // We request an NV21 stream, but many devices ignore that and deliver
        // multi-plane YUV_420_888, so rebuild a guaranteed-packed NV21 buffer
        // here before sending it across.
        final Uint8List nv21 = _yuv420ToNv21(image);
        final lines = await _channel.invokeListMethod<String>('processImage', {
          'bytes': nv21,
          'width': image.width,
          'height': image.height,
          // The buffer is packed (no row padding), so the stride equals width.
          'bytesPerRow': image.width,
          'rotation': description.sensorOrientation,
          'debug': widget.debug,
        });

        if (widget.debug) {
          log(
            'ML Kit frame ${image.width}x${image.height} '
            'rotation=${description.sensorOrientation} '
            'format=${image.format.group} '
            'planes=${image.planes.length} -> '
            '${lines?.length ?? 0} line(s): ${lines ?? const []}',
          );
        }

        if (lines != null && lines.isNotEmpty) {
          onScanLines(lines);
        }
      }

      // scanning = false;

      // Future.delayed(Duration(milliseconds: Platform.isAndroid ? 500 : 300),
      //     () {
      //   scanning = false;
      // });
    } catch (e) {
      // scanning = false;

      // scanning = false;
      if (kDebugMode) {
        rethrow;
      }
    } finally {
      if (widget.durationOfNextFrame != null) {
        Future.delayed(widget.durationOfNextFrame!, () {
          scanning = false;
        });
      } else {
        scanning = false;
      }
    }
  }

  /// Initializes the camera controller and starts the image stream.
  ///
  /// This method sets up the camera with the given [description],
  /// initializes the controller, and begins processing images for text recognition.
  Future<void> _initializeCameraController(
    CameraDescription description,
  ) async {
    final CameraController cameraController = CameraController(
      description,
      widget.resolutionPreset ??
          // Card numbers are small in frame, so a higher capture resolution
          // gives ML Kit / Apple Vision noticeably more detail to read. Default
          // Android to 1080p (veryHigh); callers can override (e.g. max) via
          // [resolutionPreset].
          (Platform.isIOS
              ? ResolutionPreset.high
              : ResolutionPreset.veryHigh),
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    controller = cameraController;

    await cameraController.initialize();

    valueLoading.value = false;

    await cameraController.startImageStream((CameraImage image) async {
      process(image, description);
    });
  }
}
