/// A launch argument the way the app opens it. Linux desktop entries hand
/// files over as file:// URIs (`Exec=icarus %U`), so one of those becomes the
/// path it names. Every other argument, an icarus: link or a plain path, is
/// kept as it is.
String launchArgumentPath(String argument) {
  if (!argument.toLowerCase().startsWith('file://')) return argument;
  final uri = Uri.tryParse(argument);
  if (uri == null || !uri.isScheme('file')) return argument;
  try {
    return uri.toFilePath();
  } on UnsupportedError {
    // A file URI naming another host, which has no local path.
    return argument;
  }
}
