import 'package:credit_card_validator/credit_card_validator.dart';
import 'package:credit_card_validator/validation_results.dart';

import 'credit_card.dart';
import 'helpers.dart';

String removeNonDigits(String text) {
  final buffer = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    final char = text[i];
    if (char.contains(RegExp(r'[0-9]'))) {
      buffer.write(char);
    }
  }
  return buffer.toString();
}

/// Formats a digits-only card number into groups of four separated by single
/// spaces (e.g. "4111111111111111" -> "4111 1111 1111 1111"), normalizing
/// whatever spacing the recognizer originally produced.
String groupCardDigits(String digits) {
  final buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i != 0 && i % 4 == 0) {
      buffer.write(' ');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// A class that processes strings to extract credit card information.
class ProccessCreditCard {
  /// The extracted credit card number.
  String cardNumber = '';

  /// The extracted cardholder name.
  String cardName = '';

  /// The extracted card expiration month.
  String cardExpirationMonth = '';

  /// The extracted card expiration year.
  String cardExpirationYear = '';

  /// Whether to check for a credit card number.
  bool checkCreditCardNumber;

  /// Whether to check for a cardholder name.
  bool checkCreditCardName;

  /// Whether to check for a credit card expiry date.
  bool checkCreditCardExpiryDate;

  /// The extracted credit card information.
  CreditCardModel? creditCardModel;

  /// A list of 4-digit number strings, used to assemble the card number.
  final numberTextList = <String>[];

  /// use Luhn algorithm to check if the number is valid
  final bool useLuhnValidation;

  /// The extracted credit card information.
  final _ccValidator = CreditCardValidator();

  /// The validation results for the card number.
  CCNumValidationResults? _v;

  /// Creates a new instance of [ProccessCreditCard].
  ///
  /// The [checkCreditCardNumber], [checkCreditCardName], and [checkCreditCardExpiryDate] parameters
  /// determine whether the processor should attempt to extract those pieces of information.
  ProccessCreditCard({
    this.cardNumber = "",
    this.cardName = "",
    this.cardExpirationMonth = "",
    this.cardExpirationYear = "",
    this.useLuhnValidation = true,
    required this.checkCreditCardNumber,
    required this.checkCreditCardName,
    required this.checkCreditCardExpiryDate,
  });

  /// Returns the full expiry date in MM/YYYY format.
  String get fullExpiryDate => '$cardExpirationMonth/$cardExpirationYear';

  /// Returns a [CreditCardModel] if all required information has been extracted.
  ///
  /// Whether a piece of information is required is determined by the
  /// [checkCreditCardNumber], [checkCreditCardName], and [checkCreditCardExpiryDate] parameters.
  CreditCardModel? getCreditCardModel() {
    final t = CreditCardModel(
      number: checkCreditCardNumber ? cardNumber : "",
      holderName: checkCreditCardName ? cardName : "",
      expirationMonth: checkCreditCardExpiryDate ? cardExpirationMonth : "",
      expirationYear: checkCreditCardExpiryDate ? cardExpirationYear : "",
    );

    if (checkCreditCardNumber && t.number.isEmpty) {
      return null;
    }

    if (checkCreditCardExpiryDate && (t.expirationMonth.isEmpty || t.expirationYear.isEmpty)) {
      return null;
    }

    t.creditCardNumberValidationResults = _v;

    creditCardModel = t;

    return creditCardModel;
  }

  /// Attempts to extract the expiry date from the given text.
  ///
  /// Returns the extracted expiry date in MM/YY format, or null if no date is found.
  String? processDate(String text) {
    if (checkCreditCardExpiryDate && text.contains('/')) {
      // OCR — especially ML Kit on Android — tends to return whole lines that
      // include surrounding labels such as "VALID THRU 05/27" or "GOOD THRU
      // 12 / 28". Instead of requiring the line to be exactly a date, search
      // for an MM/YY(YY) pattern anywhere in the text (tolerating spaces around
      // the slash that the recognizer sometimes inserts).
      for (final match in dateSearchFormat.allMatches(text)) {
        String month = match.group(1)!;
        String year = match.group(2)!;

        if (month.length == 1) {
          month = '0$month';
        }

        if (year.length >= 4) {
          year = year.substring(2);
        }

        // Completion is gated on the *month* validating — a valid month is
        // 01-12. The year is captured alongside it when present, but is not
        // required for the scan to be considered complete.
        final monthNum = int.tryParse(month);
        if (monthNum == null || monthNum < 1 || monthNum > 12) {
          continue;
        }

        cardExpirationMonth = month;
        cardExpirationYear = year;
        return fullExpiryDate;
      }
    }

    return fullExpiryDate.length > 4 ? fullExpiryDate : null;
  }

  /// Attempts to extract the cardholder name from the given text.
  ///
  /// Returns the extracted cardholder name, or null if no name is found.
  String? processName(String text) {
    if (!checkCreditCardName) {
      return null;
    }

    if (text.contains(RegExp(r'[a-zA-Z\.]'))) {
      final hasSpace = text.contains(' ');
      final hasNumber = text.contains(RegExp(r'[0-9]'));
      if (hasSpace) {
        final lines = text.split('\n');
        final validLines =
            lines.where((line) => line.trim().isNotEmpty && line.contains(' '));

        if (validLines.isNotEmpty) {
          if (hasNumber) {
            cardName = validLines.firstWhere(
              (line) => !line.contains(RegExp(r'[0-9]')),
              orElse: () => '',
            );
          } else {
            cardName = validLines.first;
          }
        }
      }
    }
    return cardName.isEmpty ? null : cardName;
  }

  /// Attempts to extract the credit card number from the given text.
  ///
  /// Returns the extracted credit card number, or null if no number is found.
  String? processNumber(String number) {
    if (!checkCreditCardNumber) {
      return null;
    }

    number = number.toLowerCase();

    // probably want to make this heuristic better
    if (number.contains("l")) {
      number = number.replaceAll("l", "1");
    }

    // The card number is often embedded in a noisier line alongside labels or
    // separated into groups by an arbitrary number of spaces/hyphens. Search
    // for candidate digit runs anywhere in the text rather than requiring the
    // whole string to be the number, then validate each candidate.
    for (final match in cardNumberSearch.allMatches(number)) {
      final candidate = removeNonDigits(match.group(0)!);

      final v = _ccValidator.validateCCNum(candidate,
          ignoreLuhnValidation: !useLuhnValidation);

      if (v.isValid) {
        // Store a normalized, consistently grouped number instead of the raw
        // OCR text so the output is independent of the original spacing.
        cardNumber = groupCardDigits(candidate);
        _v = v;

        return cardNumber;
      }
    }
    return null;
  }

  /// Processes the given text to extract credit card information.
  ///
  /// Returns a [CreditCardModel] containing the extracted information, or null if
  /// not all required information is found.
  CreditCardModel? processString(String text) {
    // Check for expiration date
    processDate(text);

    // Check for card number
    processNumber(text);

    // Check for cardholder's name
    processName(text);

    return getCreditCardModel();
  }
}
