package com.example.flutter_credit_card_scanner

import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** CreditCardScannerPlugin */
class CreditCardScannerPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel

  // Logcat tag for the ML Kit text recognizer output. Filter with
  // `adb logcat -s MLKitScanner` to see exactly what the Google model reads.
  private val TAG = "MLKitScanner"

  /// ML Kit's on-device Latin-script text recognizer. This is the only place
  /// ML Kit is referenced, so it ships with the Android build exclusively.
  private val recognizer: TextRecognizer =
    TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_credit_card_scanner")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
      "processImage" -> processImage(call, result)
      else -> result.notImplemented()
    }
  }

  /// Runs ML Kit text recognition on an NV21 camera frame and returns the
  /// recognized text as a flat list of lines for the Dart side to parse.
  private fun processImage(call: MethodCall, result: Result) {
    val bytes = call.argument<ByteArray>("bytes")
    val width = call.argument<Int>("width")
    val height = call.argument<Int>("height")
    val rotation = call.argument<Int>("rotation") ?: 0

    val debug = call.argument<Boolean>("debug") ?: false

    if (bytes == null || width == null || height == null) {
      result.error("INVALID_ARGUMENTS", "bytes, width and height are required", null)
      return
    }

    // Row stride of the luminance plane as reported by the camera. Defaults to
    // the width (i.e. assume no padding) when not provided.
    val bytesPerRow = call.argument<Int>("bytesPerRow") ?: width

    // ML Kit's NV21 reader assumes a tightly packed buffer (row stride == width).
    // If the camera delivered the frame with row padding, every row is shifted,
    // which skews the image diagonally and destroys recognition accuracy — so
    // strip the padding back to a packed NV21 buffer first.
    val packed = packNv21IfPadded(bytes, width, height, bytesPerRow)

    val image = InputImage.fromByteArray(
      packed,
      width,
      height,
      rotation,
      InputImage.IMAGE_FORMAT_NV21
    )

    if (debug) {
      val expected = width * height * 3 / 2
      Log.d(
        TAG,
        "Processing frame ${width}x${height} rotation=$rotation bytesPerRow=$bytesPerRow " +
          "(NV21 in=${bytes.size}, packed=${packed.size}, expected=$expected)"
      )
    }

    recognizer.process(image)
      .addOnSuccessListener { visionText ->
        val lines = ArrayList<String>()
        for (block in visionText.textBlocks) {
          for (line in block.lines) {
            lines.add(line.text)
          }
        }

        if (debug) {
          // Log the entire block of text the Google ML Kit model read from the
          // frame, then each recognized line individually so it's clear exactly
          // what the model is seeing on the card.
          Log.d(TAG, "ML Kit recognized full text:\n${visionText.text}")
          for (block in visionText.textBlocks) {
            for (line in block.lines) {
              Log.d(TAG, "  line: \"${line.text}\" (confidence=${line.confidence})")
            }
          }
          Log.d(TAG, "ML Kit returned ${lines.size} line(s) to Dart")
        }

        result.success(lines)
      }
      .addOnFailureListener { e ->
        if (debug) {
          Log.e(TAG, "ML Kit text recognition failed", e)
        }
        result.error("TEXT_RECOGNITION_FAILED", e.localizedMessage, null)
      }
  }

  /// Returns a tightly packed NV21 buffer, stripping row-stride padding when the
  /// reported [rowStride] is wider than [width].
  ///
  /// NV21 is laid out as a luminance (Y) plane of `height` rows followed by an
  /// interleaved chroma (VU) plane of `height / 2` rows, each row `rowStride`
  /// bytes wide of which only the first `width` bytes are valid pixels. ML Kit
  /// expects no padding, so each row is copied down to `width` bytes. If there
  /// is no padding, or the source is too small to safely repack, the original
  /// buffer is returned unchanged.
  private fun packNv21IfPadded(
    src: ByteArray,
    width: Int,
    height: Int,
    rowStride: Int,
  ): ByteArray {
    if (rowStride <= width) {
      return src
    }

    val required = rowStride * height + rowStride * (height / 2)
    if (src.size < required) {
      // Stride doesn't match the buffer we actually received; don't risk an
      // out-of-bounds copy — hand the raw bytes to ML Kit as-is.
      return src
    }

    val dst = ByteArray(width * height * 3 / 2)
    var di = 0

    // Y plane: `height` rows.
    for (row in 0 until height) {
      System.arraycopy(src, row * rowStride, dst, di, width)
      di += width
    }

    // Interleaved VU plane: `height / 2` rows, starting after the Y plane.
    val chromaStart = rowStride * height
    for (row in 0 until height / 2) {
      System.arraycopy(src, chromaStart + row * rowStride, dst, di, width)
      di += width
    }

    return dst
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    recognizer.close()
  }
}
