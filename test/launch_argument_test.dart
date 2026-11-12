import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/startup/launch_argument.dart';

void main() {
  test('a file URI from a desktop entry becomes its path', () {
    expect(
      launchArgumentPath('file:///home/ana/Strats/B%20split%20exec.ica'),
      '/home/ana/Strats/B split exec.ica',
    );
  }, testOn: 'posix');

  test('links and plain paths are kept as they are', () {
    expect(
      launchArgumentPath('icarus://auth/callback?code=x'),
      'icarus://auth/callback?code=x',
    );
    expect(launchArgumentPath('/home/ana/a.ica'), '/home/ana/a.ica');
    expect(launchArgumentPath(r'C:\Users\ana\a.ica'), r'C:\Users\ana\a.ica');
  });

  test('a file URI naming another host is kept as it is', () {
    expect(
      launchArgumentPath('file://nas/share/a.ica'),
      'file://nas/share/a.ica',
    );
  }, testOn: 'posix');
}
