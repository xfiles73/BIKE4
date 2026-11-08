import 'package:flutter/services.dart';
import 'package:windows_iap/models/product.dart';
import 'package:windows_iap/models/store_license.dart';
import 'package:windows_iap/models/trial.dart';
import 'package:windows_iap/windows_iap.dart';
import 'package:windows_iap/windows_iap_platform_interface.dart';

/// No-op replacement for the native `windows_iap` plugin.
///
/// The vendored windows_iap plugin builds its Windows half with FetchContent +
/// NuGet (Microsoft.Windows.CppWinRT) and installs C++/WinRT projection
/// headers; on some CI images that install step fails and aborts the whole
/// `flutter build windows` with MSB3073 on INSTALL.vcxproj, even though the
/// app itself compiles fine. Since this free build never completes a real
/// Microsoft-Store purchase (the app is fully unlocked and payments go
/// through Stripe), we register this Dart-only stub instead of the native
/// plugin: every Store API reports "no license / no trial", exactly like an
/// unpackaged dev build would.
class WindowsIapNoop extends WindowsIapPlatform {
  static void register() {
    WindowsIapPlatform.instance = WindowsIapNoop();
  }

  @override
  Future<StorePurchaseStatus?> makePurchase(String storeId) async => StorePurchaseStatus.notPurchased;

  @override
  Future<List<Product>> getProducts() async => const [];

  @override
  Future<bool> checkPurchase({required String storeId}) async => false;

  @override
  Future<Trial> getTrialStatusAndRemainingDays() async => Trial(
    isTrial: false,
    remainingDays: '',
    isActive: false,
    isTrialOwnedByThisUser: false,
  );

  @override
  Future<Map<String, StoreLicense>> getAddonLicenses() async => const {};

  @override
  Future<String> getCustomerPurchaseIdKey({
    required String serviceTicket,
    required String publisherUserId,
  }) async =>
      throw PlatformException(code: 'unavailable', message: 'windows_iap native plugin removed from this build');

  @override
  Future<String?> getStoreId() async => null;
}
