/// How a token off the wire is read before it is matched.
///
/// One function rather than a copy per vocabulary. Recovery tokens and pending
/// reasons are parsed in different files, and the rule that they are trimmed
/// and lowercased is the same rule: it mirrors `Recovery.fromString` on Android
/// and `Recovery(apiValue:)` on iOS, so a server that sends ` RETRY ` is read
/// the same way on every platform. Two copies could drift, and a drift here
/// looks like a value the SDK does not recognise rather than like a bug.
///
/// Null in, null out. Only the caller knows what an absent token means, and the
/// two vocabularies disagree about it: an absent recovery means retry, an
/// absent pending reason means unrecognised.
String? normalizedWireToken(String? value) => value?.trim().toLowerCase();
