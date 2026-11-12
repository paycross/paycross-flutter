/// Trims and lowercases a token off the wire before it is matched.
///
/// Recovery tokens and pending reasons share this rule, which mirrors the
/// native parsers. Null in, null out: an absent token means different things
/// to each caller.
String? normalizedWireToken(String? value) => value?.trim().toLowerCase();
