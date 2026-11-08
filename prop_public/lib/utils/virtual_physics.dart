/// Open-source physics model for virtual-shifting / SIM-mode load, written
/// from published formulas only (Andrew Coggan's cycling-power model as used
/// by GoldenCheetah/SHIFTR/TRIUMF; no proprietary source consulted).
///
/// Resistive force on the roller:
///   F = m·g·(Crr + sin(θ)) + ½·ρ·CdA·v²
/// with θ = atan(grade), ρ ≈ 1.2256 kg/m³ and a default CdA ≈ 0.3 m².
/// Required power: P = F·v. The trainer-side resistance level is derived by
/// inverting the same equation against the current speed, so shifting "up"
/// (higher gear ratio) genuinely makes the pedal effort heavier at the same
/// wheel speed — which is what the rider feels.
library;

import 'dart:math' as math;

class VirtualPhysics {
  static const double airDensityKgM3 = 1.2256;
  static const double gravityMps2 = 9.8067;
  static const double defaultCdAmpM2 = 0.3; // upright road-bike average
  static const double rollingResistanceCoefficient = 0.004; // Crr, asphalt

  /// Total resistive force [N] at [speedMps], [gradePercent] slope, combined
  /// bike+rider [massKg].
  static double resistiveForceN({
    required double speedMps,
    required double gradePercent,
    required double massKg,
    double crr = rollingResistanceCoefficient,
    double cda = defaultCdAmpM2,
  }) {
    final v = math.max(speedMps, 0.0);
    final theta = math.atan(gradePercent / 100.0);
    final friction = massKg * gravityMps2 * (crr + math.sin(theta));
    final drag = 0.5 * airDensityKgM3 * cda * v * v;
    return friction + drag;
  }

  /// Watts needed to hold [speedMps] under those conditions.
  static double requiredPowerW({
    required double speedMps,
    required double gradePercent,
    required double massKg,
    double crr = rollingResistanceCoefficient,
    double cda = defaultCdAmpM2,
  }) =>
      resistiveForceN(
        speedMps: speedMps,
        gradePercent: gradePercent,
        massKg: massKg,
        crr: crr,
        cda: cda,
      ) *
      math.max(speedMps, 0.0);

  /// Maps a target power to an FTMS resistance LEVEL in [min,max] using a
  /// quadratic law (P ∝ v·F, F ∝ level² is the common eddy-current behaviour
  /// of direct-drive trainers like the Elite Direto line). Monotonic and
  /// clamped; returns [minLevel] when maxLevel <= minLevel.
  static int powerToLevel({
    required double watts,
    required int minLevel,
    required int maxLevel,
    required double referenceWattsAtMax,
  }) {
    if (maxLevel <= minLevel) return minLevel;
    final span = maxLevel - minLevel;
    final w = math.max(watts, 0.0);
    final ref = math.max(referenceWattsAtMax, 1.0);
    // level ∝ sqrt(P) normalised so that P == reference -> level == max.
    final frac = math.sqrt(w / ref).clamp(0.0, 1.0);
    return (minLevel + (frac * span).round()).clamp(minLevel, maxLevel);
  }
}
