import 'package:flutter_test/flutter_test.dart';
import 'package:paperlight/update/version.dart';

void main() {
  test('newer versions compare greater', () {
    expect(compareVersions('v1.0.1', '1.0.0'), greaterThan(0));
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('2', '1.99.99'), greaterThan(0));
  });
  test('equal and older', () {
    expect(compareVersions('v1.2.0', '1.2.0'), 0);
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('1.2.0+7', '1.2.0'), 0);
    expect(compareVersions('1.1.9', '1.2.0'), lessThan(0));
    expect(compareVersions('', '1.0.0'), lessThan(0));
  });
}
