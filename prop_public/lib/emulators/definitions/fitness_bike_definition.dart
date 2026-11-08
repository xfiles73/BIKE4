import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/transports/ble_trainer_transport.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/ble_uuids.dart';
import 'package:prop/utils/ftms_control_point.dart';
import 'package:prop/utils/ftms_payloads.dart';
import 'package:prop/utils/virtual_physics.dart';
import 'package:universal_ble/universal_ble.dart';

/// FitnessDircon — virtual Fitness Machine (bike) that trainer apps (Zwift,
/// Rouvy, MyWhoosh, TrainerRoad…) connect to via DirCon, while this class
/// drives the REAL physical trainer over [TrainerTransport].
///
/// Reimplemented for the public build from the Bluetooth SIG specifications
/// only (FTMS v1.0, CPS v1.3, HRS v1.1) plus published open-source physics
/// models (Coggan resistive-force model as used by GoldenCheetah/SHIFTR).
/// No proprietary source was consulted or reverse-engineered.
///
/// Responsibilities:
/// - parse upstream INDOOR_BIKE_DATA / CYCLING_POWER_MEASUREMENT /
///   HEART_RATE_MEASUREMENT notifications into rider-metric notifiers;
/// - translate downstream game commands (FTMS Control Point writes coming
///   through [onWriteRequest]) into ERG target power / SIM parameters /
///   resistance levels written to the physical trainer;
/// - implement virtual shifting on top of SIM mode by scaling the effective
///   grade with the selected gear ratio;
/// - probe trainer capabilities (Feature + supported ranges) and auto-pick
///   the delivery protocol and virtual-shifting mode.
class FitnessBikeDefinition extends BleDefinition {
  final BleDevice connectedDevice;
  final List<BleService> connectedDeviceServices;
  final ValueNotifier<String> data;

  /// When true, the Zwift Play custom service is included in [serviceUUIDs]
  /// and thus advertised alongside FTMS / Cycling Power. The outer app sets
  /// this to true only when the user-selected trainer app is Zwift — other
  /// apps don't consume the Zwift service, and advertising it would just add
  /// noise to their scan results and occasionally confuse their pairing flows.
  final bool shouldAdvertiseZwift;

  /// Upstream I/O transport. Defaults to BLE via the device's id.
  final TrainerTransport transport;

  FitnessBikeDefinition({
    required this.connectedDevice,
    required this.connectedDeviceServices,
    required this.data,
    this.shouldAdvertiseZwift = false,
    TrainerTransport? transport,
  }) : transport = transport ?? BleTrainerTransport(connectedDevice.deviceId);

  // ===========================================================================
  // BLE Service / characteristic UUIDs
  // ===========================================================================

  static const String FITNESS_MACHINE_SERVICE_UUID = '00001826-0000-1000-8000-00805f9b34fb';
  static const String CYCLING_POWER_SERVICE_UUID = '00001818-0000-1000-8000-00805f9b34fb';

  static const String FITNESS_MACHINE_FEATURE_UUID = '00002acc-0000-1000-8000-00805f9b34fb';
  static const String INDOOR_BIKE_DATA_UUID = '00002ad2-0000-1000-8000-00805f9b34fb';
  static const String SUPPORTED_INCLINATION_RANGE_UUID = '00002ad5-0000-1000-8000-00805f9b34fb';
  static const String SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID = '00002ad6-0000-1000-8000-00805f9b34fb';
  static const String SUPPORTED_POWER_RANGE_UUID = '00002ad8-0000-1000-8000-00805f9b34fb';
  static const String FITNESS_MACHINE_CONTROL_POINT_UUID = '00002ad9-0000-1000-8000-00805f9b34fb';
  static const String FITNESS_MACHINE_STATUS_UUID = '00002ada-0000-1000-8000-00805f9b34fb';
  static const String TRAINING_STATUS_UUID = '00002ad3-0000-1000-8000-00805f9b34fb';

  static const String DEVICE_INFORMATION_CHARACTERISTIC_MANUFACTURER_NAME = "00002a29-0000-1000-8000-00805f9b34fb";
  static const String DEVICE_INFORMATION_CHARACTERISTIC_FIRMWARE_REVISION = "00002a26-0000-1000-8000-00805f9b34fb";
  static const String DEVICE_INFORMATION_CHARACTERISTIC_SERIAL_NUMBER = "00002a25-0000-1000-8000-00805f9b34fb";

  static const String CYCLING_POWER_MEASUREMENT_UUID = '00002a63-0000-1000-8000-00805f9b34fb';
  static const String CYCLING_POWER_FEATURE_UUID = '00002a64-0000-1000-8000-00805f9b34fb';

  /// Kept for external consumers (e.g. ProxyDircon) — this class no longer
  /// exposes a Heart Rate service itself.
  static const String HEART_RATE_MEASUREMENT_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

  ValueListenable<double> bicycleWeightKg = ValueNotifier(10.0);

  ValueListenable<double> riderWeightKg = ValueNotifier(70.0);

  static List<double> defaultGearRatios = [];

  // ===========================================================================
  // Rider metrics (fed by upstream notifications, read by the app UI)
  // ===========================================================================

  // Nullable (starts as null) to match what the app's UI/services expect:
  // TrainerMetrics, overlay controllers and self-test all read
  // `cadenceRpm.value ?? 0` / `ValueListenable<int?>`. A non-nullable notifier
  // pinned at 0 made every consumer believe the rider was stopped before the
  // first telemetry frame arrived.
  final ValueNotifier<int?> _cadenceRpmN = ValueNotifier<int?>(null);
  final ValueNotifier<double?> _speedKphN = ValueNotifier<double?>(null);
  final ValueNotifier<int?> _powerWN = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _heartRateBpmN = ValueNotifier<int?>(null);

  ValueListenable<int?> get cadenceRpm => _cadenceRpmN;
  ValueListenable<double?> get speedKph => _speedKphN;
  ValueListenable<int?> get powerW => _powerWN;
  ValueListenable<int?> get heartRateBpm => _heartRateBpmN;

  /// True when the rider picked an external sensor as the cadence/power/HR
  /// source instead of the trainer stream (setExternalCadence/Power).
  bool _externalCadenceActive = false;
  bool _externalPowerActive = false;
  bool _externalHeartRateActive = false;

  // ===========================================================================
  // Control state
  // ===========================================================================

  final ValueNotifier<TrainerMode?> _trainerModeN = ValueNotifier<TrainerMode?>(null);
  ValueListenable<TrainerMode?> get trainerMode => _trainerModeN;

  final ValueNotifier<int?> _ergTargetPowerN = ValueNotifier<int?>(null);
  ValueListenable<int?> get ergTargetPower => _ergTargetPowerN;

  final ValueNotifier<int?> _targetPowerWN = ValueNotifier<int?>(null);
  ValueListenable<int?> get targetPowerW => _targetPowerWN;

  final ValueNotifier<int> _currentGearN = ValueNotifier<int>(defaultGearRatiosFor(13).length ~/ 2);
  ValueListenable<int> get currentGear => _currentGearN;

  final ValueNotifier<double> _gearRatioN = ValueNotifier<double>(1.0);
  ValueListenable<double> get gearRatio => _gearRatioN;

  /// Seeded with the stock curve for the default gear count so the per-gear
  /// editor is never empty: setGearRatios() ignores empty lists and nothing
  /// else guarantees a first fill, which used to leave the "PER RAPPORTO"
  /// section as a blank white area until a preset was tapped.
  final ValueNotifier<List<double>> _gearRatiosN = ValueNotifier<List<double>>(defaultGearRatiosFor(13));
  ValueNotifier<List<double>> get gearRatios => _gearRatiosN;

  static int get _defaultMaxGear => 13;

  final ValueNotifier<VirtualShiftingMode?> _virtualShiftingModeN = ValueNotifier<VirtualShiftingMode?>(null);
  ValueNotifier<VirtualShiftingMode?> get virtualShiftingMode => _virtualShiftingModeN;

  final ValueNotifier<bool> _trainerFeatureN = ValueNotifier<bool>(false);
  ValueNotifier<bool> get trainerFeature => _trainerFeatureN;

  final ValueNotifier<bool> _gradeSmoothingEnabledN = ValueNotifier<bool>(true);
  ValueListenable<bool> get gradeSmoothingEnabled => _gradeSmoothingEnabledN;

  int _maxGear = 13;
  int get maxGear => _maxGear;
  /// True when there is a neutral (reference) gear in the middle of the
  /// cassette; false for single-gear setups, where every gear is relative to
  /// itself. Never throws — the UI reads it while building rows.
  bool get hasNeutralGear => _maxGear > 1;

  /// The neutral (reference) gear, 1-based and inside the current curve;
  /// 0 when there is none.
  int get neutralGear {
    if (!hasNeutralGear || _gearRatiosN.value.isEmpty) return 0;
    return math.min((_maxGear + 1) ~/ 2, _gearRatiosN.value.length);
  }

  // ── Capability probes ─────────────────────────────────────────────────────
  FtmsFeature? _feature;
  int _resMin = 1;
  int _resMax = 24;
  int _powerMin = 0;
  int _powerMax = 2000;
  double _simGradeMinPct = -10;
  double _simGradeMaxPct = 10;
  bool _probed = false;

  // ── Current simulated world state ─────────────────────────────────────────
  double _gameGradePercent = 0; // raw grade requested by the app (SIM)
  double _smoothedGradePercent = 0;
  int _windMpsx1000 = 0;
  double _crrNPerKg = VirtualPhysics.rollingResistanceCoefficient;
  double _lastControlGradeSent = double.nan;

  // CP cadence derivation (crank revolution deltas), per CPS spec.
  int? _lastCrankRevs;
  int? _lastCrankEventTime;
  DateTime? _lastCrankWall;

  StreamSubscription<({String characteristic, Uint8List value})>? _upstreamSub;
  Timer? _telemetryTimer;
  bool _disposed = false;

  // ===========================================================================
  // Protocol selection
  // ===========================================================================

  TrainerControlProtocol? _controlProtocolOverride;

  /// The delivery the trainer is actually driven over: the rider's
  /// [controlProtocolOverride] when set, otherwise auto-detection.
  TrainerControlProtocol get controlProtocol => _controlProtocolOverride ?? TrainerControlProtocol.ftms;

  /// The rider's forced delivery, or null for auto.
  TrainerControlProtocol? get controlProtocolOverride => _controlProtocolOverride;

  /// Every delivery this trainer can actually carry.
  Set<TrainerControlProtocol> get supportedControlProtocols => {
    if (_feature != null || !_probed) TrainerControlProtocol.ftms,
    // FE-C over BLE (Tacx-style vendor service) detected during discovery.
    if (connectedDeviceServices.any((s) => TrainerUuids.matches(s.uuid, TrainerUuids.fecService)))
      TrainerControlProtocol.fec,
  };

  void setControlProtocolOverride(TrainerControlProtocol? p) {
    _controlProtocolOverride = p;
    _log('protocol override: ${p?.name ?? 'auto'}');
  }

  /// The mode virtual shifting is actually driven with, which can differ from
  /// the saved [virtualShiftingMode].
  VirtualShiftingMode get effectiveVirtualShiftingMode =>
      _virtualShiftingModeN.value ?? defaultVirtualShiftingMode;

  /// The mode auto-selection would pick for this trainer: Track Resistance
  /// when the machine supports incline/SIM grade control (it can feel the
  /// shift as a real grade change), otherwise Target Power.
  VirtualShiftingMode get defaultVirtualShiftingMode =>
      (_feature?.simulatedModeSupported ?? true) ? VirtualShiftingMode.trackResistance : VirtualShiftingMode.targetPower;

  /// Hands the virtual-shifting mode back to auto-selection.
  void useDefaultVirtualShiftingMode() => _virtualShiftingModeN.value = null;

  /// Compact FTMS capability line for the support bundle.
  String get ftmsCapabilitySummary => _feature == null
      ? 'FTMS feature: not probed'
      : 'FTMS: ${_feature!.flagNames.join(', ')} | res $_resMin-$_resMax | pow $_powerMin-$_powerMax W';

  /// The cadence the resistance calculation actually uses.
  /// Null-safe: before the first telemetry frame (or after an external source
  /// is deselected) the notifier holds null, which we treat as "stopped".
  int get filteredCadence {
    final rpm = _cadenceRpmN.value ?? 0;
    if (!_cadenceFilterEnabledN.value) return rpm;
    // Simple low-pass: ignore single-sample dropouts below 20 rpm.
    return rpm < 20 ? _lastStableCadence : rpm;
  }

  int _lastStableCadence = 0;

  /// Compact Zwift-Sync handshake line for the support bundle; 'n/a' when the
  /// trainer does not speak it.
  String get zwiftHandshakeSummary => 'n/a';

  /// Compact native gear-acknowledgement line for the support bundle; 'n/a'
  /// when the trainer does not speak it.
  String get gearEchoSummary => 'n/a';

  /// How the gear echo watchdog resolved, or null while nothing is wrong.
  final ValueNotifier<ZwiftGearEchoVerdict?> gearEchoVerdict = ValueNotifier<ZwiftGearEchoVerdict?>(null);

  /// Whether the trainer refused to start grade simulation.
  final ValueNotifier<bool> trackResistanceRefused = ValueNotifier<bool>(false);

  /// The most recent upstream control write, or null before the first one.
  ControlWriteResult? _lastControlWrite;
  ControlWriteResult? get lastControlWrite => _lastControlWrite;

  // ===========================================================================
  // Rider metrics sourced by the app rather than the trainer
  // ===========================================================================

  /// Passing null hands the quantity back to the trainer stream (and clears
  /// the last external reading), which is what the app does when the rider
  /// deselects an external sensor source.
  void setExternalHeartRate(int? bpm) {
    _externalHeartRateActive = bpm != null;
    _update(_heartRateBpmN, bpm);
  }

  void setExternalCadence(int? rpm) {
    _externalCadenceActive = rpm != null;
    _update(_cadenceRpmN, rpm);
  }

  void setExternalPower(int? watts) {
    _externalPowerActive = watts != null;
    _update(_powerWN, watts);
  }

  List<String>? get trainerFtmsMachineFeatureFlagNames => _feature?.flagNames;

  List<String>? get trainerFtmsTargetSettingFlagNames => _feature == null
      ? null
      : [
          if (_feature!.manualResistanceMode) 'Manual Resistance Mode',
          if (_feature!.resistanceControlModeAvailable) 'Resistance Control Mode',
          if (_feature!.simulatedModeSupported) 'Simulated Mode',
          if (_feature!.inclineControlModeSupported) 'Inclination Control Mode',
        ];

  /// Reads FTMS Feature + supported ranges from the physical trainer and
  /// derives capability-based defaults. Idempotent; safe to call again after
  /// a reconnect.
  Future<void> probeTrainerFeatures() async {
    try {
      final services = await transport.discoverServices();
      handleUpstreamServices(services);
      for (final s in services) {
        for (final c in s.characteristics) {
          final uuid = TrainerUuids.shortForm(c.uuid);
          try {
            if (uuid == TrainerUuids.ftmsFeature && TrainerUuids.matches(s.uuid, TrainerUuids.ftmsService)) {
              final f = decodeFtmsFeature(await transport.read(s.uuid, c.uuid));
              if (f != null) {
                _feature = f;
                _trainerFeatureN.value = true;
                _log('feature: ${f.flagNames.join(', ')}');
              }
            } else if (uuid == TrainerUuids.supportedResistanceLevelRange) {
              final b = await transport.read(s.uuid, c.uuid);
              if (b.length >= 4) {
                final bd = ByteData.sublistView(b);
                _resMax = bd.getUint8(1);
                _resMin = bd.getUint8(2);
                _log('resistance range: $_resMin-$_resMax');
              }
            } else if (uuid == TrainerUuids.supportedPowerRange) {
              final b = await transport.read(s.uuid, c.uuid);
              if (b.length >= 5) {
                final bd = ByteData.sublistView(b);
                _powerMax = bd.getUint16(1, Endian.little);
                _powerMin = bd.getInt16(3, Endian.little);
                _log('power range: $_powerMin..$_powerMax W');
              }
            } else if (uuid == TrainerUuids.supportedInclinationRange) {
              final b = await transport.read(s.uuid, c.uuid);
              if (b.length >= 5) {
                final bd = ByteData.sublistView(b);
                _simGradeMaxPct = bd.getInt16(1, Endian.little) / 100.0;
                _simGradeMinPct = bd.getInt16(3, Endian.little) / 100.0;
                _log('grade range: $_simGradeMinPct%..$_simGradeMaxPct%');
              }
            }
          } catch (e) {
            debugPrint('FitnessBikeDefinition: read $uuid failed: $e');
          }
        }
      }
      _probed = true;
      _recomputeGearRatio();
      _applyCurrentControlState();
    } catch (e) {
      _log('feature probe failed: $e');
    }
  }

  // ===========================================================================
  // Configuration setters (seeded by the app from ShiftingConfig)
  // ===========================================================================

  void setMaxGear(int maxGear) {
    final prev = _maxGear;
    _maxGear = math.max(maxGear, 1);
    // Grow/shrink the editable curve in place so per-gear edits made at the
    // old count survive a gear-count change; only replace it wholesale when
    // there is nothing to resize (fresh/empty notifier).
    final current = _gearRatiosN.value;
    if (current.isEmpty) {
      _gearRatiosN.value = defaultGearRatiosFor(_maxGear);
    } else if (_maxGear != prev || current.length != _maxGear) {
      final defaults = defaultGearRatiosFor(_maxGear);
      final resized = <double>[];
      for (var i = 0; i < _maxGear; i++) {
        resized.add(i < current.length ? current[i] : defaults[i]);
      }
      _gearRatiosN.value = resized;
    }
    _clampGearIndex();
    _recomputeGearRatio();
  }

  void setBicycleWeightKg(double bikeWeightKg) {
    (bicycleWeightKg as ValueNotifier<double>).value = bikeWeightKg;
    _pushSimulationIfNeeded();
  }

  void setRiderWeightKg(double riderWeightKg) {
    (this.riderWeightKg as ValueNotifier<double>).value = riderWeightKg;
    _pushSimulationIfNeeded();
  }

  void setGradeSmoothingEnabled(bool gradeSmoothing) => _gradeSmoothingEnabledN.value = gradeSmoothing;

  void setVirtualShiftingMode(VirtualShiftingMode mode) {
    _virtualShiftingModeN.value = mode;
    _applyCurrentControlState();
  }

  /// Install an entire curve. When [exactLength] is true the list is stored
  /// as-is (preset semantics — a preset defines exactly its own gears);
  /// otherwise it is grown/shrunk to the current [_maxGear], padding with the
  /// stock defaults so the per-gear editor always has one row per gear.
  void setGearRatios(List<double> list, {bool exactLength = false}) {
    if (list.isEmpty) return;
    var values = List<double>.from(list);
    if (!exactLength && values.length != _maxGear) {
      // The saved curve can be shorter (or longer) than the configured
      // cassette (older configs, presets with a different gear count). Match
      // it to the gear count instead of letting the editor index past its
      // end: a mismatched list used to throw inside the row builder and blank
      // out the whole "per gear" section.
      final defaults = defaultGearRatiosFor(_maxGear);
      if (values.length < _maxGear) {
        for (var i = values.length; i < _maxGear; i++) {
          values.add(defaults[i]);
        }
      } else {
        values = values.sublist(0, _maxGear);
      }
    }
    _gearRatiosN.value = values;
    _clampGearIndex();
    _recomputeGearRatio();
  }

  /// Manual ERG target (the +/- buttons and slider land here). Also drives
  /// the trainer immediately when we are already in ERG.
  void setManualErgPower(int watts) {
    final w = watts.clamp(0, 2000);
    _ergTargetPowerN.value = w;
    if (_trainerModeN.value == TrainerMode.ergMode) {
      unawaited(_sendControl('setTargetPower(manual)', ftmsSetTargetPower(w)));
    }
  }

  bool shiftUp() {
    final gears = _gearRatiosN.value;
    if (gears.isEmpty) return false;
    final next = math.min(_currentGearN.value + 1, gears.length - 1);
    if (next == _currentGearN.value) return false;
    setTargetGear(next);
    return true;
  }

  bool shiftDown() {
    final gears = _gearRatiosN.value;
    if (gears.isEmpty) return false;
    final next = math.max(_currentGearN.value - 1, 0);
    if (next == _currentGearN.value) return false;
    setTargetGear(next);
    return true;
  }

  void exitErgMode() {
    _ergTargetPowerN.value = null;
    _trainerModeN.value = null;
    _unwatchGameCommand();
    _pushSimulationIfNeeded();
  }

  /// Relative intensity nudge, as sent by the app's +/- intensity buttons:
  /// +0.05 means "5% harder", -0.05 means "5% easier". The scale is clamped
  /// to a sane 10%…300% of the game-set load and re-applied immediately.
  void adjustIntensity(double delta) {
    _intensityScale = (_intensityScale + delta).clamp(0.1, 3.0);
    _applyCurrentControlState();
  }

  double _intensityScale = 1.0;

  bool supportsVirtualShiftingMode(VirtualShiftingMode value) => switch (value) {
    VirtualShiftingMode.targetPower => true,
    VirtualShiftingMode.trackResistance => _feature?.simulatedModeSupported ?? true,
    VirtualShiftingMode.basicResistance => _feature?.resistanceControlModeAvailable ?? true,
  };

  static List<double> defaultGearRatiosFor(int count) {
    if (count <= 0) return [];
    // Cassette-like spread normalised so the middle gear ≈ 1.0.
    const base = [0.62, 0.68, 0.75, 0.82, 0.89, 0.97, 1.06, 1.16, 1.27, 1.39, 1.52];
    if (count == base.length) return List<double>.from(base);
    final out = <double>[];
    for (var i = 0; i < count; i++) {
      final src = base[(i * base.length / count).floor().clamp(0, base.length - 1)];
      out.add(src);
    }
    return out;
  }

  /// Set the coefficient of one gear. [gear] is **1-based** (the editor's row
  /// number), matching every caller in the UI; internally it maps to index
  /// `gear - 1`. A previous revision treated it as a 0-based index, which made
  /// row 1 write into slot 2 and — for the last row — grow the curve by one
  /// element on every tap until the per-gear section threw itself blank.
  void setGearRatio(int gear, double v) {
    if (gear < 1) return;
    final idx = gear - 1;
    final list = List<double>.from(_gearRatiosN.value);
    // Never extend past the configured cassette: pad only up to _maxGear so a
    // stray call cannot desync the curve length from the gear count.
    final targetLength = math.min(math.max(idx + 1, list.length), _maxGear);
    if (idx >= _maxGear) return;
    while (list.length < targetLength) {
      list.add(defaultGearRatiosFor(_maxGear)[list.length]);
    }
    if (idx >= list.length) return;
    list[idx] = v;
    _gearRatiosN.value = list;
    _recomputeGearRatio();
  }

  void resetGearRatios() {
    _gearRatiosN.value = defaultGearRatiosFor(_maxGear);
    _currentGearN.value = neutralGear;
    _recomputeGearRatio();
  }

  void setTargetGear(int i) {
    _currentGearN.value = i.clamp(0, math.max(_gearRatiosN.value.length - 1, 0));
    _recomputeGearRatio();
    _pushSimulationIfNeeded();
  }

  void _clampGearIndex() {
    if (_currentGearN.value >= _gearRatiosN.value.length) {
      _currentGearN.value = math.max(_gearRatiosN.value.length - 1, 0);
    }
  }

  void _recomputeGearRatio() {
    final gears = _gearRatiosN.value;
    if (gears.isEmpty) {
      _gearRatioN.value = 1.0;
      return;
    }
    var ratio = gears[_currentGearN.value.clamp(0, gears.length - 1)];
    if (_frontShiftEnabled) {
      ratio *= _frontRingN.value == FrontRing.large ? _largeChainringTeeth / _smallChainringTeeth : 1.0;
    }
    _gearRatioN.value = ratio;
  }

  // FAKE placeholder UUID.
  static const String FEC_BLE_SERVICE_UUID = '00000000-0000-0000-0000-0000000000c0';

  final ValueNotifier<bool> _cadenceFilterEnabledN = ValueNotifier(false);
  ValueListenable<bool> get cadenceFilterEnabled => _cadenceFilterEnabledN;
  void setCadenceFilterEnabled(bool enabled) {
    _cadenceFilterEnabledN.value = enabled;
  }

  bool _frontShiftEnabled = false;
  int _smallChainringTeeth = 34;
  int _largeChainringTeeth = 50;
  final ValueNotifier<FrontRing> _frontRingN = ValueNotifier<FrontRing>(FrontRing.small);
  ValueListenable<FrontRing> get frontRing => _frontRingN;
  int get smallChainringTeeth => _smallChainringTeeth;
  int get largeChainringTeeth => _largeChainringTeeth;
  bool get frontShiftEnabled => _frontShiftEnabled;

  void setFrontShiftEnabled(bool enabled) {
    _frontShiftEnabled = enabled;
    if (!enabled) _frontRingN.value = FrontRing.small;
    _recomputeGearRatio();
  }

  void setChainringTeeth(int small, int large) {
    _smallChainringTeeth = math.max(small, 1);
    _largeChainringTeeth = math.max(large, _smallChainringTeeth);
    _frontRingN.value = FrontRing.small;
    _recomputeGearRatio();
  }

  Future<bool> writeClimbInclineUpstream(int grade001Pct) async {
    // Wahoo Climb Special opcode path is proprietary; on FTMS-only trainers
    // the equivalent is a SIM-parameter grade write.
    final pct = grade001Pct / 100.0;
    _gameGradePercent = pct;
    _setSimGrade(pct);
    await _pushSimulation(force: true);
    return true;
  }

  /// Subscribes the transport to every notify/indicate characteristic of the
  /// discovered trainer services and starts routing them here. This is what
  /// makes telemetry flow: without CCCD enablement a trainer never sends
  /// INDOOR_BIKE_DATA / CP measurements.
  void subscribeToTrainer() {
    _startUpstreamRouting();
    unawaited(ensureTrainerSubscriptions());
  }

  /// Enables CCCD notifications on the physical trainer without installing a
  /// second notification listener: the bridge device already relays trainer
  /// values into [onNotification], so this only turns the tap on.
  Future<void> ensureTrainerSubscriptions() async {
    if (_disposed) return;
    final t = transport;
    if (t is BleTrainerTransport) {
      await t.subscribeToAllDiscovered(connectedDeviceServices);
      return;
    }
    for (final s in connectedDeviceServices) {
      for (final c in s.characteristics) {
        final props = c.properties;
        final canNotify = props.contains(CharacteristicProperty.notify);
        final canIndicate = props.contains(CharacteristicProperty.indicate);
        if (!canNotify && !canIndicate) continue;
        try {
          await t.subscribe(s.uuid, c.uuid, indicate: canIndicate && !canNotify);
        } catch (e) {
          debugPrint('FitnessBikeDefinition: subscribe ${c.uuid} failed: $e');
        }
      }
    }
    _log('subscribed to trainer notifications');
  }

  void _startUpstreamRouting() {
    if (_upstreamSub != null || _disposed) return;
    _upstreamSub = transport.notifications.listen(_handleUpstreamNotification, onError: (Object e) {
      _log('upstream stream error: $e');
    });
    transport.onDisconnected = () {
      _log('trainer disconnected');
      isConnectedToTrainer = false;
    };
  }

  void handleUpstreamServices(List<BleService> services) {
    // Remembered for subscription; nothing else to derive right now.
  }

  bool isConnectedToTrainer = false;

  // ===========================================================================
  // Downstream client-facing GATT surface (what the trainer app sees)
  // ===========================================================================

  @override
  List<String> get serviceUUIDs => [
    FITNESS_MACHINE_SERVICE_UUID,
    CYCLING_POWER_SERVICE_UUID,
    if (shouldAdvertiseZwift) '0000fd54-0000-1000-8000-00805f9b34fb', // ZWIFT_PLAY_SERVICE
  ];

  @override
  List<String> get advertiseServiceUUIDs => [
    '0000fd55-0000-1000-8000-00805f9b34fb', // DirCon service
    ...serviceUUIDs,
  ];

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) {
    final s = TrainerUuids.normalizeUuid(serviceUUID);
    if (s == TrainerUuids.normalizeUuid(FITNESS_MACHINE_SERVICE_UUID)) {
      return [
        _ch(FITNESS_MACHINE_FEATURE_UUID, [CharacteristicProperty.read]),
        _ch(INDOOR_BIKE_DATA_UUID, [CharacteristicProperty.notify]),
        _ch(SUPPORTED_INCLINATION_RANGE_UUID, [CharacteristicProperty.read]),
        _ch(SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID, [CharacteristicProperty.read]),
        _ch(SUPPORTED_POWER_RANGE_UUID, [CharacteristicProperty.read]),
        _ch(FITNESS_MACHINE_CONTROL_POINT_UUID, [CharacteristicProperty.write, CharacteristicProperty.indicate]),
        _ch(FITNESS_MACHINE_STATUS_UUID, [CharacteristicProperty.indicate]),
        _ch(TRAINING_STATUS_UUID, [CharacteristicProperty.notify]),
      ];
    }
    if (s == TrainerUuids.normalizeUuid(CYCLING_POWER_SERVICE_UUID)) {
      return [
        _ch(CYCLING_POWER_MEASUREMENT_UUID, [CharacteristicProperty.notify]),
        _ch(CYCLING_POWER_FEATURE_UUID, [CharacteristicProperty.read]),
      ];
    }
    return const [];
  }

  static const String _FTMS_CONTROL_POINT_UUID = '00002ad9-0000-1000-8000-00805f9b34fb';

  /// Current smoothed simulated grade in percent (what the trainer app last
  /// requested through SIM mode, after smoothing). Used by the app's incline
  /// controller (e.g. Elite Sterzo/Rizer physical steering wheels).
  /// Null until SIM mode has actually been entered — the pre-SIM value is a
  /// default, not a request, so sinks must not act on it.
  ValueListenable<double?> get simGrade => _simGradeN;
  final ValueNotifier<double?> _simGradeN = ValueNotifier<double?>(null);

  void _setSimGrade(double pct) {
    _smoothedGradePercent = pct;
    if (_simGradeN.value != pct) _simGradeN.value = pct;
  }

  /// Forget the current grade (SIM mode exited / reset): the notifier goes
  /// back to null so downstream consumers stop driving the incline sink with
  /// a stale value.
  void _clearSimGrade() {
    if (_simGradeN.value != null) _simGradeN.value = null;
  }

  // universal_ble's BleCharacteristic takes three *positional* arguments
  // (uuid, properties, descriptors) — named-argument calls don't compile.
  BleCharacteristic _ch(String uuid, List<CharacteristicProperty> props) =>
      BleCharacteristic(uuid, props, const []);

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) {
    final c = TrainerUuids.shortForm(characteristicUUID);
    switch (c) {
      case '2acc': // FTMS Feature — expose our own capability bitmap.
        return Future.value(_buildClientFeature());
      case '2ad9': // FTMS Control Point — a readable GATT attribute is not
        // defined by the profile (write + indicate only); answer with an empty
        // payload so clients probing it never hit an exception.
        return Future.value(Uint8List(0));
      case '2ad5': // Supported Inclination Range
        final b = ByteData(6)
          ..setInt16(0, (_simGradeMinPct * 10).round(), Endian.little)
          ..setInt16(2, (_simGradeMaxPct * 10).round(), Endian.little)
          ..setUint16(4, 1, Endian.little);
        return Future.value(b.buffer.asUint8List());
      case '2ad6': // Supported Resistance Level Range
        final b = ByteData(6)
          ..setInt16(0, _resMin, Endian.little)
          ..setInt16(2, _resMax, Endian.little)
          ..setInt16(4, 1, Endian.little);
        return Future.value(b.buffer.asUint8List());
      case '2ad8': // Supported Power Range
        final b = ByteData(6)
          ..setInt16(0, _powerMin, Endian.little)
          ..setInt16(2, _powerMax, Endian.little)
          ..setInt16(4, 1, Endian.little);
        return Future.value(b.buffer.asUint8List());
      case '2a64': // Cycling Power Feature: crank revolution data supported.
        return Future.value(Uint8List.fromList([0x08, 0, 0, 0]));
      default:
        return null;
    }
  }

  Uint8List _buildClientFeature() {
    // Fitness Machine Features: Average Speed (0), Cadence (1), Inclination
    // (3), Resistance Level (7), Heart Rate (10), Power Measurement (14).
    // Resistance Level is advertised because the Indoor Bike Data frames we
    // push to the game include that field.
    const machineFeatures =
        (1 << 0) | (1 << 1) | (1 << 3) | (1 << 7) | (1 << 10) | (1 << 14);
    const targetSettings = (1 << 2) | (1 << 3) | (1 << 13);
    final b = ByteData(8)
      ..setUint32(0, machineFeatures, Endian.little)
      ..setUint32(4, targetSettings, Endian.little);
    return b.buffer.asUint8List();
  }

  void _sendControlPointResponse(int requestOpcode, int resultCode) {
    sendCharacteristicNotification(
      FITNESS_MACHINE_CONTROL_POINT_UUID,
      [FtmsOp.responseCode, requestOpcode, resultCode],
    );
  }

  /// A game wrote to our exposed FTMS Control Point.
  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {
    final c = TrainerUuids.shortForm(characteristicUUID);
    if (c != TrainerUuids.shortForm(FITNESS_MACHINE_CONTROL_POINT_UUID)) return;
    if (characteristicData.isEmpty) return;
    final bytes = Uint8List.fromList(characteristicData);
    final bd = ByteData.sublistView(bytes);
    final op = bd.getUint8(0);
    switch (op) {
      case FtmsOp.requestControl:
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      case FtmsOp.setTargetPower:
        if (bytes.length != 3) {
          _sendControlPointResponse(op, FtmsOp.failureParameterOutOfRange);
          break;
        }
        final w = bd.getInt16(1, Endian.little);
        _enterErg(w);
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      case FtmsOp.setIndoorBikeSimulationParameters:
        if (bytes.length != 7) {
          _sendControlPointResponse(op, FtmsOp.failureParameterOutOfRange);
          break;
        }
        _enterSim(bytes, bd);
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      case FtmsOp.setTargetResistanceLevel:
        if (bytes.length != 3) {
          _sendControlPointResponse(op, FtmsOp.failureParameterOutOfRange);
          break;
        }
        final level = bd.getInt16(1, Endian.little);
        _trainerModeN.value = null;
        unawaited(_sendControl('setResistance(game)', ftmsSetTargetResistanceLevel(level)));
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      case FtmsOp.start:
        unawaited(_sendControl('start', ftmsSimpleOp(FtmsOp.start)));
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      case FtmsOp.stopOrPause:
        if (bytes.length != 2 || bytes[1] > 1) {
          _sendControlPointResponse(op, FtmsOp.failureParameterOutOfRange);
          break;
        }
        final pause = bytes[1] == 1;
        unawaited(_sendControl(pause ? 'pause' : 'stop', ftmsStopOrPause(pause: pause)));
        if (!pause) _unwatchGameCommand();
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      case FtmsOp.reset:
        _unwatchGameCommand();
        _ergTargetPowerN.value = null;
        _gameGradePercent = 0;
        _setSimGrade(0);
        _trainerModeN.value = null;
        _sendControlPointResponse(op, FtmsOp.failureSuccess);
        break;
      default:
        _log('unhandled FTMS CP opcode 0x${op.toRadixString(16)}');
        _sendControlPointResponse(op, FtmsOp.failureOpcodeNotSupported);
    }
  }

  void _enterErg(int watts) {
    _unwatchGameCommand();
    _trainerModeN.value = TrainerMode.ergMode;
    _ergTargetPowerN.value = watts;
    _targetPowerWN.value = watts;
    unawaited(_sendControl('setTargetPower', ftmsSetTargetPower(watts)));
    // Ownership of the ERG target expires if the game stops commanding.
    _gameCommandTimer = Timer(const Duration(seconds: 5), () {
      if (_trainerModeN.value == TrainerMode.ergMode) _unwatchGameCommand();
    });
  }

  void _enterSim(Uint8List bytes, ByteData bd) {
    _unwatchGameCommand();
    _trainerModeN.value = effectiveVirtualShiftingMode == VirtualShiftingMode.targetPower
        ? TrainerMode.simMode
        : TrainerMode.simModeVirtualShifting;
    if (bytes.length >= 7) {
      _windMpsx1000 = bd.getInt16(1, Endian.little);
      _gameGradePercent = bd.getInt16(3, Endian.little) / 100.0;
      _crrNPerKg = bd.getUint8(5) * 0.005;
    }
    _setSimGrade(_gameGradePercent);
    unawaited(_pushSimulation(force: true));
    // SIM parameter freshness window (games re-send at least every ~10 s).
    _gameCommandTimer = Timer(const Duration(seconds: 10), () {
      if (_trainerModeN.value != TrainerMode.ergMode) _unwatchGameCommand();
    });
  }

  Timer? _gameCommandTimer;
  void _unwatchGameCommand() {
    _gameCommandTimer?.cancel();
    _gameCommandTimer = null;
  }

  // ===========================================================================
  // Upstream notification handling
  // ===========================================================================

  void _handleUpstreamNotification(({String characteristic, Uint8List value}) event) {
    if (_disposed) return;
    final c = TrainerUuids.shortForm(event.characteristic);
    switch (c) {
      case TrainerUuids.indoorBikeData:
        final ibd = decodeIndoorBikeData(event.value);
        if (ibd == null) return;
        if (!_externalPowerActive && ibd.powerWatts != null) _update(_powerWN, ibd.powerWatts);
        if (!_externalCadenceActive) {
          final rpmRaw = ibd.rpmCadence ?? ibd.cadenceRevPerMin;
          if (rpmRaw != null) {
            final rpm = rpmRaw.round();
            if (rpm >= 20) _lastStableCadence = rpm;
            _update(_cadenceRpmN, rpm);
          }
        }
        if (ibd.speedKph != null) _update(_speedKphN, ibd.speedKph);
        if (!_externalHeartRateActive && ibd.heartRateBpm != null) _update(_heartRateBpmN, ibd.heartRateBpm);
        isConnectedToTrainer = true;
        _maybePushSmoothedGrade();
        break;
      case TrainerUuids.cyclingPowerMeasurement:
        final cp = decodeCyclingPowerMeasurement(event.value);
        if (cp == null) return;
        if (!_externalPowerActive && cp.powerWatts != null) _update(_powerWN, cp.powerWatts);
        if (!_externalCadenceActive) {
          final rpmDerived = _deriveCadenceFromCrank(cp);
          if (rpmDerived != null) {
            final rpm = rpmDerived.round();
            if (rpm >= 20) _lastStableCadence = rpm;
            _update(_cadenceRpmN, rpm);
          }
        }
        isConnectedToTrainer = true;
        break;
      case TrainerUuids.heartRateMeasurement:
        if (!_externalHeartRateActive) {
          final hr = decodeHeartRate(event.value);
          if (hr != null) _update(_heartRateBpmN, hr);
        }
        break;
      case TrainerUuids.ftmsStatus:
      case TrainerUuids.trainingStatus:
        final msg = describeMachineStatus(event.value);
        _log(msg);
        final r = decodeMachineStatus(event.value);
        if (r != null && r.isResponse && r.failureCode != FtmsOp.failureSuccess) {
          _lastControlWrite = ControlWriteResult(at: DateTime.now(), ok: false, op: 'resp${r.requestOpCode}');
          if (r.requestOpCode == FtmsOp.setIndoorBikeSimulationParameters &&
              effectiveVirtualShiftingMode == VirtualShiftingMode.trackResistance) {
            trackResistanceRefused.value = true;
          }
        }
        break;
      default:
        break;
    }
  }

  num? _deriveCadenceFromCrank(CyclingPowerData cp) {
    if (cp.crankRevolutions == null || cp.lastCrankEventTime1024ths == null) return null;
    final now = DateTime.now();
    final prevRevs = _lastCrankRevs;
    final prevEvt = _lastCrankEventTime;
    final prevWall = _lastCrankWall;
    _lastCrankRevs = cp.crankRevolutions;
    _lastCrankEventTime = cp.lastCrankEventTime1024ths;
    _lastCrankWall = now;
    if (prevRevs == null || prevEvt == null || prevWall == null) return null;
    var dRevs = cp.crankRevolutions! - prevRevs;
    if (dRevs < 0) dRevs += 0x10000; // uint16 wraparound
    final dtWall = now.difference(prevWall).inMilliseconds / 1000.0;
    if (dRevs == 0 || dtWall <= 0 || dtWall > 5) return null;
    // Prefer wall-clock delta (robust against event-time quantisation).
    return (dRevs / dtWall * 60).round().clamp(0, 300);
  }

  // ===========================================================================
  // Control loop
  // ===========================================================================

  void _applyCurrentControlState() {
    switch (_trainerModeN.value) {
      case TrainerMode.ergMode:
        final t = _ergTargetPowerN.value;
        if (t != null) unawaited(_sendControl('setTargetPower(mode)', ftmsSetTargetPower(t)));
        break;
      case TrainerMode.simMode:
      case TrainerMode.simModeVirtualShifting:
      case null:
        unawaited(_pushSimulation(force: true));
        break;
    }
  }

  /// Grade smoothing: ramp toward the game grade instead of slamming the
  /// trainer with each new SIM write.
  void _maybePushSmoothedGrade() {
    if (!_gradeSmoothingEnabledN.value) return;
    if ((_smoothedGradePercent - _gameGradePercent).abs() < 0.05) return;
    _setSimGrade(_smoothedGradePercent + (_gameGradePercent - _smoothedGradePercent) * 0.25);
    unawaited(_pushSimulation(smoothedStep: true));
  }

  Future<void> _pushSimulation({bool force = false, bool smoothedStep = false}) async {
    final mode = effectiveVirtualShiftingMode;
    if (!smoothedStep && !force && _trainerModeN.value == null) return;

    final grade = _smoothedGradePercent;

    if (mode == VirtualShiftingMode.targetPower || _trainerModeN.value == TrainerMode.simMode) {
      // Target-Power VS: compute the physics load for the current gear and
      // drive the trainer in ERG at that wattage.
      final speedMps = (_speedKphN.value ?? 0) / 3.6;
      final mass = bicycleWeightKg.value + riderWeightKg.value;
      final ratio = _gearRatioN.value;
      final base = VirtualPhysics.requiredPowerW(
        speedMps: speedMps,
        gradePercent: grade,
        massKg: mass,
        crr: _crrNPerKg,
      );
      final watts = (base * ratio * _intensityScale).round().clamp(_powerMin, _powerMax);
      _targetPowerWN.value = watts;
      await _sendControl('erg(virtual-gear)', ftmsSetTargetPower(watts));
    } else if (mode == VirtualShiftingMode.trackResistance) {
      // Track-Resistance VS: rewrite the effective grade by the gear ratio so
      // the trainer's own SIM physics produces the shifted feel.
      final scaled = (grade * _gearRatioN.value * _intensityScale).clamp(_simGradeMinPct, _simGradeMaxPct);
      if (!force && !smoothedStep && (scaled - _lastControlGradeSent).abs() < 0.1) return;
      _lastControlGradeSent = scaled;
      await _sendControl(
        'sim(vs-grade)',
        ftmsSetSimulationParameters(
          windSpeedMps: _windMpsx1000 / 1000.0,
          gradePercent: scaled,
          crrNPerKg: _crrNPerKg,
          totalMassKg: (bicycleWeightKg.value + riderWeightKg.value).round(),
        ),
      );
    } else {
      // Basic resistance: map the physics load onto the level scale.
      final speedMps = (_speedKphN.value ?? 0) / 3.6;
      final mass = bicycleWeightKg.value + riderWeightKg.value;
      final base = VirtualPhysics.requiredPowerW(
        speedMps: speedMps,
        gradePercent: grade,
        massKg: mass,
        crr: _crrNPerKg,
      );
      final level = VirtualPhysics.powerToLevel(
        watts: (base * _gearRatioN.value * _intensityScale).clamp(0.0, _powerMax.toDouble()),
        minLevel: _resMin,
        maxLevel: _resMax,
        referenceWattsAtMax: _powerMax.toDouble(),
      );
      await _sendControl('resistance(basic)', ftmsSetTargetResistanceLevel(level));
    }
  }

  Future<void> _sendControl(String op, Uint8List payload) async {
    if (_disposed) return;
    try {
      await transport.write(FITNESS_MACHINE_SERVICE_UUID, FITNESS_MACHINE_CONTROL_POINT_UUID, payload);
      _lastControlWrite = ControlWriteResult(at: DateTime.now(), ok: true, op: op);
    } catch (e) {
      _lastControlWrite = ControlWriteResult(at: DateTime.now(), ok: false, op: '$op: $e');
      _log('control write failed ($op): $e');
    }
  }

  // ===========================================================================
  // Client telemetry push (1 Hz synthetic notifications to the game)
  // ===========================================================================

  @override
  void onEnableNotificationRequest(String characteristicUUID) {
    final c = TrainerUuids.shortForm(characteristicUUID);
    if (c == TrainerUuids.shortForm(INDOOR_BIKE_DATA_UUID) ||
        c == TrainerUuids.shortForm(CYCLING_POWER_MEASUREMENT_UUID)) {
      _startTelemetryLoop();
    }
  }

  void _startTelemetryLoop() {
    if (_telemetryTimer != null) return;
    // Push one frame right away (deferred one turn so it can't overtake the
    // ENABLE reply on the wire): games often show "no signal" until the first
    // notification arrives, and waiting a full second delays the pairing UI.
    Timer.run(_pushClientTelemetry);
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pushClientTelemetry());
  }

  void _pushClientTelemetry() {
    if (_disposed) return;
    final now = DateTime.now();
    final rawDt = _lastTelemetryAt == null ? 1.0 : now.difference(_lastTelemetryAt!).inMicroseconds / 1e6;
    final dt = rawDt.clamp(0.0, 5.0).toDouble();
    _lastTelemetryAt = now;

    final speedKph = (_speedKphN.value ?? 0).clamp(0.0, 120.0);
    final cadenceRpm = (_cadenceRpmN.value ?? 0).clamp(0, 250);
    final powerW = (_powerWN.value ?? 0).clamp(0, 3000);
    final bpm = (_heartRateBpmN.value ?? 0).clamp(0, 255);

    // FTMS INDOOR_BIKE_DATA (0x2AD2), Fitness Machine Service 1.0 §4.9.1.
    // Field order is fixed by the flag bitmap below; every game decodes it in
    // this order, so any deviation shifts all following values.
    //   0x0004 Instantaneous Cadence (uint16, 0.5 rpm)
    //   0x0020 Resistance Level      (sint16)
    //   0x0040 Instantaneous Power   (sint16, W)
    //   0x0200 Heart Rate            (uint8, bpm)
    // Instantaneous Speed (uint16, 0.01 km/h) is always present because the
    // "More Data" bit (0x0001) is clear.
    const ibdFlags = 0x0004 | 0x0020 | 0x0040 | 0x0200;
    final ibd = ByteData(11)
      ..setUint16(0, ibdFlags, Endian.little)
      ..setUint16(2, (speedKph * 100).round().clamp(0, 0xFFFF), Endian.little)
      ..setUint16(4, (cadenceRpm * 2).clamp(0, 0xFFFF), Endian.little)
      ..setInt16(6, 0, Endian.little) // resistance level
      ..setInt16(8, powerW, Endian.little)
      ..setUint8(10, bpm);
    sendCharacteristicNotification(INDOOR_BIKE_DATA_UUID, ibd.buffer.asUint8List());

    // CYCLING_POWER_MEASUREMENT (0x2A63): flags + mandatory Instantaneous
    // Power, then Crank Revolution Data (0x0020): cumulative revolutions
    // (uint16) and last crank event time (uint16, 1/1024 s). The event time
    // advances per completed revolution (61440/1024 = 60 s worth of ticks per
    // minute at the current cadence), like a real power meter.
    _clientCrankRevsFrac += cadenceRpm / 60.0 * dt;
    final wholeRevs = _clientCrankRevsFrac.floor();
    if (wholeRevs > 0) {
      _clientCrankRevs = (_clientCrankRevs + wholeRevs) & 0xFFFF;
      if (cadenceRpm > 0) {
        _clientCrankEvt = (_clientCrankEvt + (wholeRevs * 61440 / cadenceRpm).round()) & 0xFFFF;
      }
      _clientCrankRevsFrac -= wholeRevs;
    }

    final cp = ByteData(8)
      ..setUint16(0, 0x0020, Endian.little)
      ..setInt16(2, powerW, Endian.little)
      ..setUint16(4, _clientCrankRevs, Endian.little)
      ..setUint16(6, _clientCrankEvt, Endian.little);
    sendCharacteristicNotification(CYCLING_POWER_MEASUREMENT_UUID, cp.buffer.asUint8List());
  }

  DateTime? _lastTelemetryAt;
  double _clientCrankRevsFrac = 0;
  int _clientCrankRevs = 0;
  int _clientCrankEvt = 0;

  /// Test seam: emit one telemetry frame without waiting for the 1 Hz timer.
  @visibleForTesting
  void pushTelemetryForTesting() => _pushClientTelemetry();

  @override
  void onNotification(String characteristic, Uint8List bytes) {
    // Upstream trainer notifications reach the definition here: ProxyDevice
    // listens to the trainer transport and hands every value to the emulator's
    // processCharacteristic(), which routes it to the child owning the
    // characteristic. Decode them into the rider metrics; the telemetry we
    // push to the game is built from those.
    if (bytes.isEmpty) return;
    _handleUpstreamNotification((characteristic: characteristic, value: bytes));
  }

  void _log(String message) {
    data.value = '${DateTime.now().toIso8601String().substring(11)} $message';
  }

  void _update<T>(ValueNotifier<T?> n, T value) {
    if (n.value != value) n.value = value;
  }

  /// Test seam: inject a decoded FTMS Feature without a live transport, so
  /// capability-driven UI (VS-mode cards) can be exercised in widget tests.
  @visibleForTesting
  void setTrainerFeatureForTesting(FtmsFeature feature) {
    _feature = feature;
    _probed = true;
    _trainerFeatureN.value = true;
    _recomputeGearRatio();
  }

  /// Test seam: stubbed.
  void setDebugValues() {}

  bool get supportsClimbRelay => false;

  bool toggleFrontChainring() {
    if (!_frontShiftEnabled) return false;
    _frontRingN.value = _frontRingN.value == FrontRing.small ? FrontRing.large : FrontRing.small;
    _recomputeGearRatio();
    _pushSimulationIfNeeded();
    return true;
  }

  void _pushSimulationIfNeeded() {
    final mode = _trainerModeN.value;
    if (mode == TrainerMode.simMode || mode == TrainerMode.simModeVirtualShifting) {
      unawaited(_pushSimulation(force: true));
    } else if (mode == TrainerMode.ergMode && effectiveVirtualShiftingMode == VirtualShiftingMode.targetPower) {
      // ERG owned by the game: shifting adjusts the game target multiplicatively.
      final t = _ergTargetPowerN.value;
      if (t != null) {
        unawaited(_sendControl('erg(gear-scaled)', ftmsSetTargetPower((t * _gearRatioN.value).round())));
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _telemetryTimer?.cancel();
    _gameCommandTimer?.cancel();
    unawaited(_upstreamSub?.cancel());
    _upstreamSub = null;
    _simGradeN.dispose();
    final t = transport;
    if (t is BleTrainerTransport) t.dispose();
  }

  @override
  void debug() => _log(ftmsCapabilitySummary);
}

/// Outcome of the most recent control write sent upstream to the trainer.
class ControlWriteResult {
  final DateTime at;
  final bool ok;
  final String op;
  const ControlWriteResult({required this.at, required this.ok, required this.op});
}

/// How the gear echo watchdog resolved, once a trainer has ignored enough
/// native gear commands — see [FitnessBikeDefinition.gearEchoVerdict].
enum ZwiftGearEchoVerdict {
  /// Delivery moved to FTMS automatically.
  fellBackToFtms,

  /// The trainer has no FTMS Control Point; the native path stays.
  noFtmsToFallBackTo,

  /// The rider forced a protocol; that choice is kept.
  riderOverrideKept,
}

enum FrontRing { small, large }

enum TrainerMode { ergMode, simMode, simModeVirtualShifting }

enum VirtualShiftingMode { targetPower, trackResistance, basicResistance }

/// The wire a trainer's control commands are delivered over.
enum TrainerControlProtocol { ftms, fec, zwiftHub }
