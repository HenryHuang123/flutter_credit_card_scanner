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

// ---------------------------------------------------------------------------
// Scan confirmation tuning.
//
// A single OCR frame is noisy, so a value is never trusted on first sight.
// Instead the most recent [_kHistoryLength] detected card numbers and expiry
// dates are kept independently, and a value is only "locked in" (and the
// onScan callback fired) once the same value has been seen [_kRequiredMatches]
// times. This filters out one-off misreads and stops the callback from firing
// on every frame. Both are overridable per-widget via the constructor.
// ---------------------------------------------------------------------------

/// Number of times the same value must be detected before it is locked in.
const int _kRequiredMatches = 2;

/// How many recent detections of each field are remembered when looking for a
/// repeated value.
const int _kHistoryLength = 10;

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

  /// Maximum number of camera frames forwarded to the recognizer each second.
  ///
  /// The camera streams frames far faster than OCR can keep up with. Forwarding
  /// every frame floods the recognizer and makes the preview feel laggy, so
  /// frames that arrive sooner than `1 / framesPerSecond` after the last
  /// processed frame are dropped. Defaults to 3 frames per second, which is
  /// plenty for reading a stationary card.
  final int framesPerSecond;

  /// Number of times the same value (card number or expiry date) must be
  /// detected across frames before it is locked in and reported via [onScan].
  ///
  /// Raising this trades a little speed for fewer misreads. Defaults to
  /// [_kRequiredMatches].
  final int requiredMatches;

  /// How many recent detections of each field are remembered when looking for a
  /// repeated value. Defaults to [_kHistoryLength].
  final int historyLength;

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
    this.framesPerSecond = 3,
    this.requiredMatches = _kRequiredMatches,
    this.historyLength = _kHistoryLength,
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

  final appleVisionController = apple.AppleVisionRecognizeTextController(
    minimumTextHeight: 0.1,
    usesLanguageCorrection: false,
  );

  /// The camera controller used to manage the device's camera.
  CameraController? controller;

  /// Notifier to manage the loading state of the camera.
  final valueLoading = ValueNotifier<bool>(true);

  /// Flag to prevent multiple simultaneous scans.
  bool scanning = false;

  /// Timestamp of the last frame that was forwarded to the recognizer, used to
  /// throttle the stream down to [CameraScannerWidget.framesPerSecond].
  DateTime? _lastFrameTime;

  /// Minimum gap between processed frames, derived from
  /// [CameraScannerWidget.framesPerSecond].
  late final Duration _minFrameInterval = Duration(
    milliseconds: (1000 / widget.framesPerSecond).round(),
  );

  /// Rolling history of recently detected card numbers / expiry dates (kept
  /// independently). A value is locked in once it recurs [requiredMatches]
  /// times within the last [historyLength] detections. See the file-level docs.
  final List<String> _numberHistory = [];
  final List<String> _dateHistory = [];

  /// Values that have been confirmed (seen enough times) and will not change.
  String? _lockedNumber;
  String? _lockedMonth;
  String? _lockedYear;

  /// Most recently seen cardholder name. The name is not confirmation-gated
  /// (it is optional for completion); the latest non-empty value is kept.
  String _latestName = '';

  /// Computes the scan-window crop rectangle and crops frames to it. Its
  /// fractions also drive the on-screen overlay so the two stay in sync.
  final ScanWindowCropper _cropper = const ScanWindowCropper();

  Color get colorOverlay =>
      widget.colorOverlay ?? Colors.black.withValues(alpha: 0.8);

  /// Diagnostics-only logging that can never break scanning.
  ///
  /// `dart:developer`'s [log] writes through the VM Service, which goes away
  /// when a debug build is detached from its host (e.g. the device is unplugged
  /// from the machine that ran it). A failed write must not be allowed to abort
  /// the frame it happens on — most importantly the one that fires [onScan] —
  /// so every diagnostic log is gated on [CameraScannerWidget.debug] and
  /// wrapped so any error is swallowed.
  void _safeLog(String message) {
    if (!widget.debug) return;
    try {
      log(message);
    } catch (_) {
      // Logging is best-effort; never let it interrupt a scan.
    }
  }

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
                              cutOutHeight:
                                  size.height * _cropper.heightFraction,
                              cutOutWidth: size.width * _cropper.widthFraction,
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
          _safeLog(error.toString());
          _safeLog(stackTrace.toString());
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
  Future<void> onScanLines(List<String> lines) async {
    for (final line in lines) {
      _safeLog(line);
    }

    // Run the regex + Luhn/validator extraction inline on the UI isolate.
    //
    // This used to run on a background isolate via compute() to keep the accept
    // path off the UI isolate, but spawning an isolate is fatal in a detached
    // iOS debug build: debug builds JIT-compile, iOS only allows JIT while the
    // debugger is attached, and a freshly spawned isolate must JIT its entry —
    // so the app crashed the moment it was unplugged. The extraction is a regex
    // + Luhn pass over a handful of lines a few times a second, so running it
    // here is cheap and keeps the scanner working detached and in release.
    final result = _parseLinesIsolate(
      _ParseRequest(
        lines: lines,
        useLuhnValidation: widget.useLuhnValidation,
        checkNumber: widget.cardNumber,
        checkName: widget.cardHolder,
        checkExpiry: widget.cardExpiryDate,
      ),
    );

    if (!mounted) return;

    _registerCandidate(result);
  }

  /// Feeds one frame's extracted candidates into the rolling histories, locks
  /// in any value seen [CameraScannerWidget.requiredMatches] times, and reports
  /// the card via [onScan] each time everything required is confirmed.
  void _registerCandidate(_ParseResult result) {
    if (widget.cardNumber &&
        _lockedNumber == null &&
        result.number.isNotEmpty) {
      _record(_numberHistory, result.number);
      if (_occurrences(_numberHistory, result.number) >=
          widget.requiredMatches) {
        _lockedNumber = result.number;
      }
    }

    if (widget.cardExpiryDate &&
        _lockedMonth == null &&
        result.month.isNotEmpty &&
        result.year.isNotEmpty) {
      final key = '${result.month}/${result.year}';
      _record(_dateHistory, key);
      if (_occurrences(_dateHistory, key) >= widget.requiredMatches) {
        _lockedMonth = result.month;
        _lockedYear = result.year;
      }
    }

    if (result.name.isNotEmpty) {
      _latestName = result.name;
    }

    _maybeEmit();
  }

  /// Appends [value] to [history], capping it at [historyLength] by dropping the
  /// oldest entry.
  void _record(List<String> history, String value) {
    history.add(value);
    if (history.length > widget.historyLength) {
      history.removeAt(0);
    }
  }

  /// Number of times [value] appears in [history].
  int _occurrences(List<String> history, String value) =>
      history.where((e) => e == value).length;

  /// Reports the confirmed card whenever every required field is locked in.
  ///
  /// This only ever calls the [onScan] callback — it never triggers a rebuild
  /// of this widget, so the camera preview is untouched. After firing, the
  /// histories and locks are cleared so the scanner immediately re-arms and can
  /// confirm the next card (or re-confirm the current one) without any restart.
  void _maybeEmit() {
    if (widget.cardNumber && _lockedNumber == null) return;
    if (widget.cardExpiryDate && _lockedMonth == null) return;

    final model = CreditCardModel(
      number: widget.cardNumber ? (_lockedNumber ?? '') : '',
      holderName: widget.cardHolder ? _latestName : '',
      expirationMonth: widget.cardExpiryDate ? (_lockedMonth ?? '') : '',
      expirationYear: widget.cardExpiryDate ? (_lockedYear ?? '') : '',
    );

    // Fire the consumer callback before logging: delivering the scan is the
    // whole point, and logging is best-effort (see [_safeLog]). Ordering it
    // first means a logging hiccup can never keep the scan from being reported.
    if (mounted) widget.onScan(context, model);
    _safeLog('Scanning locked in card: $model');

    // Re-arm for the next card.
    _numberHistory.clear();
    _dateHistory.clear();
    _lockedNumber = null;
    _lockedMonth = null;
    _lockedYear = null;
    _latestName = '';
  }

  void process(CameraImage image, CameraDescription description) async {
    // Drop the frame if a previous one is still being recognized...
    if (scanning) return;

    // ...or if it arrived too soon after the last processed frame. This caps
    // the work at [framesPerSecond] regardless of how fast the camera streams.
    final now = DateTime.now();
    if (_lastFrameTime != null &&
        now.difference(_lastFrameTime!) < _minFrameInterval) {
      return;
    }
    _lastFrameTime = now;

    scanning = true;

    if (widget.debug) {
      // Surface the real frame layout. If `planes` is 3 the device handed back
      // multi-plane YUV_420_888 rather than the single-plane NV21 we requested,
      // which is why feeding the raw bytes to ML Kit produced garbage.
      final expectedNv21 = (image.width * image.height * 3) ~/ 2;
      _safeLog(
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
        // Restrict Apple Vision to the scan window via regionOfInterest instead
        // of cropping the buffer — Vision skips everything outside it, so the
        // full frame is handed over untouched.
        final textR = await appleVisionController.processImage(
          apple.RecognizeTextData(
            automaticallyDetectsLanguage: false,
            languages: [const Locale('en', 'US')],
            recognitionLevel: apple.RecognitionLevel.accurate,
            image: image.planes.first.bytes,
            orientation: appleOrientationFromSensor(
              description.sensorOrientation,
            ),
            imageSize: Size(image.width.toDouble(), image.height.toDouble()),
            regionOfInterest: _cropper.visionRegionOfInterest(),
          ),
        );

        if (textR?.isNotEmpty == true) {
          final lines = <String>[
            for (final item in textR!) ...item.listText,
          ];
          await onScanLines(lines);
        }
      } else {
        // Android: ML Kit has no region-of-interest, so crop to the scan window
        // ourselves (on a background isolate). The result is packed NV21
        // (stride == width).
        final crop = _cropper.rectFor(
          image.width,
          image.height,
          description.sensorOrientation,
        );
        final Uint8List cropped = await _cropper.crop(image, crop);
        final lines = await _channel.invokeListMethod<String>('processImage', {
          'bytes': cropped,
          'width': crop.width,
          'height': crop.height,
          'bytesPerRow': crop.width,
          'rotation': description.sensorOrientation,
          'debug': widget.debug,
        });

        if (widget.debug) {
          _safeLog(
            'ML Kit frame ${crop.width}x${crop.height} '
            '(cropped from ${image.width}x${image.height}) '
            'rotation=${description.sensorOrientation} '
            'format=${image.format.group} '
            'planes=${image.planes.length} -> '
            '${lines?.length ?? 0} line(s): ${lines ?? const []}',
          );
        }

        if (lines != null && lines.isNotEmpty) {
          await onScanLines(lines);
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

/// One frame's recognized text lines plus the extraction flags, sent to the
/// background isolate that parses them (see [_parseLinesIsolate]).
class _ParseRequest {
  final List<String> lines;
  final bool useLuhnValidation;
  final bool checkNumber;
  final bool checkName;
  final bool checkExpiry;

  const _ParseRequest({
    required this.lines,
    required this.useLuhnValidation,
    required this.checkNumber,
    required this.checkName,
    required this.checkExpiry,
  });
}

/// The card fields extracted from a single frame. Empty strings mean "not found
/// in this frame".
class _ParseResult {
  final String number;
  final String name;
  final String month;
  final String year;

  const _ParseResult({
    required this.number,
    required this.name,
    required this.month,
    required this.year,
  });
}

/// Extracts card fields from one frame's text lines. Runs on a background
/// isolate via [compute] so no regex/Luhn validation happens on the UI isolate.
///
/// A fresh [ProccessCreditCard] is used per call so the result reflects only
/// this frame — cross-frame confirmation is handled by the widget's rolling
/// histories instead.
_ParseResult _parseLinesIsolate(_ParseRequest req) {
  final process = ProccessCreditCard(
    useLuhnValidation: req.useLuhnValidation,
    checkCreditCardNumber: req.checkNumber,
    checkCreditCardName: req.checkName,
    checkCreditCardExpiryDate: req.checkExpiry,
  );

  for (final line in req.lines) {
    process.processNumber(line);
    process.processName(line);
    process.processDate(line);
  }

  // ML Kit / Apple Vision frequently break a card number or expiry date across
  // several lines. Re-run number/date detection over the combined text so
  // fragments such as "4111 1111" + "1111 1111" can be reassembled. Letters
  // break a digit run and each candidate is still Luhn-validated, so joining
  // the lines does not produce false positives. Only attempt this when the
  // per-line pass came up empty so a value already found is never clobbered.
  if (process.cardNumber.isEmpty || process.cardExpirationMonth.isEmpty) {
    final joined = req.lines.join(' ');
    if (process.cardNumber.isEmpty) process.processNumber(joined);
    if (process.cardExpirationMonth.isEmpty) process.processDate(joined);
  }

  return _ParseResult(
    number: process.cardNumber,
    name: process.cardName,
    month: process.cardExpirationMonth,
    year: process.cardExpirationYear,
  );
}
