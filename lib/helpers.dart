import 'package:apple_vision_commons/apple_vision_commons.dart';

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
final RegExp dateSearchFormat = RegExp(r'(\d{1,2})\s*\/\s*(\d{2,4})');

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
