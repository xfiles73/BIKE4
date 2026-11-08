import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/ftms_control_point.dart';

void main() {
  test('control point command builders use FTMS assigned opcodes', () {
    expect(ftmsSetTargetPower(250), [0x05, 0xfa, 0x00]);
    expect(ftmsSetTargetResistanceLevel(6), [0x04, 0x06, 0x00]);
    expect(
      ftmsSetSimulationParameters(
        windSpeedMps: 0,
        gradePercent: 1,
        crrNPerKg: 0.005,
        totalMassKg: 80,
      ).first,
      0x11,
    );
    expect(ftmsSimpleOp(FtmsOp.start), [0x07]);
    expect(ftmsStopOrPause(pause: false), [0x08, 0x00]);
    expect(ftmsStopOrPause(pause: true), [0x08, 0x01]);
  });
}
