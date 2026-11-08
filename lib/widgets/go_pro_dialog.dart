import 'package:bike_control/utils/iap/iap_manager.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Shows a dialog prompting the user to upgrade to Pro.
///
/// [featureName] names the thing the rider just reached for. Pass it wherever
/// the entry point is an icon or a toggle: "Pro Feature" alone tells them the
/// price of something they never found out the name of.
///
/// The app is fully free now — all Pro features are unlocked, so this dialog
/// is never shown and the function simply reports that no purchase was made.
/// Kept as a no-op stub so existing call sites keep compiling.
Future<bool> showGoProDialog(BuildContext context, {String? featureName}) async {
  return false;
}
