import 'dart:async';
import 'dart:io';

import 'package:bike_control/utils/auth/account_session.dart';
import 'package:bike_control/services/device_identity_service.dart';
import 'package:bike_control/services/device_management_service.dart';
import 'package:bike_control/services/entitlements_service.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/iap/revenuecat_service.dart';
import 'package:bike_control/utils/iap/windows_iap_service.dart';
import 'package:bike_control/utils/windows_store_environment.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum SubscriptionPlan {
  monthly,
  yearly,
}

/// Unified IAP manager that handles platform-specific IAP services.
class IAPManager {
  static IAPManager? _instance;
  static IAPManager get instance {
    _instance ??= IAPManager._();
    return _instance!;
  }

  static const String premiumMonthlyProductKey = 'premium_monthly';
  static const String premiumYearlyProductKey = 'premium_yearly';
  static const String fullVersionProductKey = 'full_version';
  static const String betaAccessProductKey = 'beta_access';
  static int dailyCommandLimit = 15;

  RevenueCatService? _revenueCatService;
  WindowsIAPService? _windowsIapService;
  StreamSubscription<AuthState>? _authSubscription;
  bool _isInitialized = false;

  final DeviceIdentityService deviceIdentity = DeviceIdentityService();
  late final DeviceManagementService deviceManagement = DeviceManagementService(
    supabase: core.supabase,
    deviceIdentityService: deviceIdentity,
  );
  late final EntitlementsService entitlements = EntitlementsService(
    core.supabase,
    deviceIdentityService: deviceIdentity,
  );

  // The app is fully free: both notifiers start (and stay) true so every UI
  // that listens on them — trial card, banners, status widget — shows the
  // unlocked Pro state from the very first frame.
  ValueNotifier<bool> isPurchased = ValueNotifier<bool>(true);
  ValueNotifier<bool> isLocalPro = ValueNotifier<bool>(true);

  IAPManager._();

  /// Signed into a real account. The anonymous session the support chat
  /// creates on demand doesn't count, so a store-bought Pro user who never
  /// signed in keeps the local (RevenueCat) entitlement path.
  bool get isLoggedIn => hasAccount(core.supabase.auth.currentSession?.user);

  /// The Supabase user id RevenueCat was last logged in as by
  /// [_handleAuthStateChange]; null while there's no account.
  String? _revenueCatUserId;

  /// Pure decision behind the RevenueCat login in [_handleAuthStateChange]:
  /// who to log in as and whether to run `sync-subscriptions`, or null to
  /// leave RevenueCat alone. Anonymous users are never used as a RevenueCat
  /// identity. Syncs on a fresh sign-in or launch, and whenever the account
  /// differs from [previousUserId] — e.g. an anonymous session that just
  /// became an account by linking an email keeps its id but only fires
  /// `userUpdated`.
  @visibleForTesting
  static ({String userId, bool performSync})? revenueCatLogin({
    required AuthChangeEvent event,
    required User? user,
    required String? previousUserId,
  }) {
    if (user == null || !hasAccount(user)) return null;
    final freshSession = event == AuthChangeEvent.initialSession || event == AuthChangeEvent.signedIn;
    return (userId: user.id, performSync: freshSession || user.id != previousUserId);
  }

  /// Whether the logged-in user is flagged for the Shorebird beta update
  /// track (a manual `beta_access` entitlement granted from the admin
  /// dashboard). Reads the cached entitlements; false when logged out or
  /// before the first entitlements fetch.
  bool get isBetaTester => (isLoggedIn && entitlements.hasActive(betaAccessProductKey) || kDebugMode);

  bool get hasActiveSubscription => true;

  // The app is fully free now: every Pro entitlement check short-circuits to
  // true, unlocking all previously paid features and removing all limitations.
  // The subscription/purchase machinery below is kept intact but is no longer
  // consulted for gating decisions.
  bool get isProEnabled => true;

  bool get isProEnabledForCurrentDevice => true;

  /// Pro is on the account but this device is not registered for it, so the
  /// Pro-gated features stay off here. Riders in this state used to see only
  /// "Pro (unregistered device)" in the title bar and wrote in believing Pro
  /// was broken — the home banner, the virtual-shifting notice and the
  /// post-purchase dialog all key off this.
  bool get isProButDeviceUnregistered => false;

  bool get isProEnabledForCurrentDeviceOrDidPurchaseOld => true;

  /// Test-only: makes [isProEnabledForCurrentDevice] report false while
  /// [isProEnabled] holds — the state a logged-in rider lands in when the
  /// device could not be registered (platform limit reached). Nothing in the
  /// production paths sets it.
  bool _unregisteredDeviceForTesting = false;

  /// Test-only: force the Pro entitlement state so Pro-gated actions/UI can be
  /// exercised without a live subscription or device registration.
  /// [registeredDevice] false yields "Pro on the account, not on this device".
  /// No-op: the app is fully free, the entitlement state is always unlocked.
  @visibleForTesting
  void setProForTesting({required bool enabled, bool registeredDevice = true}) {
    _isInitialized = true;
  }

  bool get hasPurchasedBefore50RVC =>
      isPurchased.value &&
      ((_revenueCatService?.hasPurchasedBefore50 ?? false) || (_windowsIapService?.hasPurchasedBefore50 ?? false));

  DateTime? get premiumActiveUntil =>
      entitlements.activeUntil(premiumMonthlyProductKey) ?? entitlements.activeUntil(premiumYearlyProductKey);

  /// Initialize the IAP manager.
  Future<void> initialize() async {
    if (_isInitialized) return;

    final prefs = FlutterSecureStorage(aOptions: AndroidOptions());
    await entitlements.initialize();
    entitlements.addListener(_onEntitlementsChanged);
    _bindAuthLifecycle();

    if (kIsWeb) {
      _isInitialized = true;
      return;
    }

    try {
      if (Platform.isWindows) {
        _windowsIapService = WindowsIAPService(
          prefs,
          entitlementsService: entitlements,
        );
        await _windowsIapService!.initialize();
      } else if (Platform.isIOS || Platform.isMacOS || Platform.isAndroid) {
        _revenueCatService = RevenueCatService(
          prefs,
          isPurchasedNotifier: isPurchased,
          isProNotifier: isLocalPro,
          getDailyCommandLimit: () => dailyCommandLimit,
          setDailyCommandLimit: (limit) => dailyCommandLimit = limit,
          entitlementsService: entitlements,
          premiumProductKeyMonthly: premiumMonthlyProductKey,
          premiumProductKeyYearly: premiumYearlyProductKey,
        );
        await _revenueCatService!.initialize();
      } else {
        throw UnsupportedError('Unsupported platform for IAP: ${Platform.operatingSystem}');
      }

      await entitlements.refresh();
      _syncPurchaseFlagFromEntitlements();
      _isInitialized = true;
    } catch (e) {
      debugPrint('Error initializing IAP manager: $e');
      _isInitialized = true;
    }
  }

  /// Called on app start when a session may already exist.
  Future<void> refreshEntitlementsOnAppStart() async {
    await entitlements.refresh(force: true);
    _syncPurchaseFlagFromEntitlements();
  }

  /// Called on app resume to refresh stale entitlement cache.
  Future<void> refreshEntitlementsOnResume() async {
    await entitlements.refresh();
    _syncPurchaseFlagFromEntitlements();
  }

  /// Check if the trial period has started. The app is free now, so the trial
  /// is considered always started (and never expiring).
  bool get hasTrialStarted => true;

  /// Start the trial period.
  Future<void> startTrial() async {
    if (_revenueCatService != null) {
      await _revenueCatService!.startTrial();
    }
  }

  /// Get the number of days remaining in the trial. Free app: no trial
  /// countdown anymore.
  int get trialDaysRemaining => 0;

  /// Check if the trial has expired. The app is free now — it never expires.
  bool get isTrialExpired => false;

  /// Check if the user can execute a command. Free app: no command limits.
  bool get canExecuteCommand => true;

  /// Get the number of commands remaining today. Free app: unlimited (-1).
  int get commandsRemainingToday => -1;

  /// Get the daily command count.
  int get dailyCommandCount {
    if (_revenueCatService != null) {
      return _revenueCatService!.dailyCommandCount;
    } else if (_windowsIapService != null) {
      return _windowsIapService!.dailyCommandCount;
    }
    return 0;
  }

  /// Increment the daily command count. No-op: the app is free and unlimited.
  Future<void> incrementCommandCount() async {}

  /// Get a status message for the user. The app is free now — everyone is Pro.
  String getStatusMessage() {
    if (kIsWeb) {
      return "Web";
    }
    return 'Pro';
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    // when today return full time, otherwise just date
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    } else {
      return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
    }
  }

  /// Purchase the full version. The app is free now, so there is nothing to
  /// buy — this is kept as a no-op for compatibility with existing call sites.
  Future<void> purchaseFullVersion(BuildContext context, {bool fromPaywall = false}) async {}

  /// Purchase a subscription. The app is free now, so there is nothing to
  /// buy — this is kept as a no-op for compatibility with existing call sites.
  Future<void> purchaseSubscription(
    BuildContext context, {
    SubscriptionPlan plan = SubscriptionPlan.monthly,
    bool fromPaywall = false,
  }) async {}

  /// Restore previous purchases.
  Future<void> restorePurchases() async {
    if (_revenueCatService != null) {
      await _revenueCatService!.restorePurchases();
    } else if (_windowsIapService != null) {}
    _syncPurchaseFlagFromEntitlements();
  }

  /// Check if RevenueCat is being used.
  bool get isUsingRevenueCat => _revenueCatService != null;

  /// Check if running on Windows
  bool get isWindows => _windowsIapService != null;

  bool get isOutsideStoreWindowsBuild =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows && WindowsStoreEnvironment.isOutsideStoreCached;

  /// Check if user is logged in (Windows Stripe requires this)
  bool get isWindowsLoggedIn => _windowsIapService?.isLoggedIn ?? false;

  /// Open Stripe Billing Portal (Windows only)
  /// Returns false if user has no Stripe customer (should hide button)
  Future<bool> openBillingPortal(BuildContext context) async {
    if (_revenueCatService != null) {
      return _revenueCatService!.openBillingPortal(context);
    } else if (_windowsIapService != null) {
      return _windowsIapService!.openBillingPortal(context);
    } else {
      return false;
    }
  }

  /// Check if user has a Stripe customer record (Windows only)
  Future<bool> hasStripeCustomer() async {
    if (_windowsIapService == null) return false;
    return _windowsIapService!.hasStripeCustomer();
  }

  /// Dispose the manager.
  void dispose() {
    _authSubscription?.cancel();
    entitlements.removeListener(_onEntitlementsChanged);
    _revenueCatService?.dispose();
    _windowsIapService?.dispose();
  }

  Future<void> reset(bool fullReset) async {
    // The app is fully free: never downgrade the unlocked state.
    await entitlements.clearCache();
    _windowsIapService?.reset();
    await _revenueCatService?.reset(fullReset);
  }

  Future<void> redeem(String purchaseId) async {
    if (_revenueCatService != null) {
      await _revenueCatService!.redeem(purchaseId);
      await entitlements.refresh(force: true);
      _syncPurchaseFlagFromEntitlements();
    }
  }

  void setAttributes() {
    _revenueCatService?.setAttributes();
  }

  void _bindAuthLifecycle() {
    _authSubscription ??= core.supabase.auth.onAuthStateChange.listen((data) {
      unawaited(_handleAuthStateChange(data.event, data.session));
    });
  }

  Future<void> _handleAuthStateChange(AuthChangeEvent event, Session? session) async {
    switch (event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.tokenRefreshed:
      case AuthChangeEvent.userUpdated:
      case AuthChangeEvent.mfaChallengeVerified:
        final login = revenueCatLogin(event: event, user: session?.user, previousUserId: _revenueCatUserId);
        if (login != null) {
          _revenueCatUserId = login.userId;
          await _revenueCatService?.logInWithSupabaseUserId(login.userId, performSync: login.performSync);
        }
        await _revenueCatService?.setAttributes();
        await entitlements.refresh(force: true);
        _syncPurchaseFlagFromEntitlements();
        // A rider who tapped Buy on the Windows Stripe build while logged out was
        // sent to the login gate; a genuine `signedIn` is our cue to finish the
        // checkout they started. Skip token refreshes / the initial session,
        // which are not a fresh login and would fire on every launch.
        if (event == AuthChangeEvent.signedIn && isLoggedIn) {
          await _windowsIapService?.resumePendingPurchaseAfterLogin(isAlreadyPro: isProEnabled);
        }
        return;
      case AuthChangeEvent.signedOut:
      // ignore: deprecated_member_use
      case AuthChangeEvent.userDeleted:
        _revenueCatUserId = null;
        await _revenueCatService?.logOut();
        await entitlements.clearCache();
        // reset isPurchased value
        if (Platform.isWindows) {
          await _windowsIapService?.initialize();
        } else if (Platform.isIOS || Platform.isMacOS || Platform.isAndroid) {
          await _revenueCatService?.initialize();
        }
        return;
      case AuthChangeEvent.passwordRecovery:
        return;
    }
  }

  void _onEntitlementsChanged() {
    _syncPurchaseFlagFromEntitlements();
  }

  void _syncPurchaseFlagFromEntitlements() {
    if (isProEnabled) {
      isPurchased.value = true;
    } else if (isOutsideStoreWindowsBuild && entitlements.hasActive(fullVersionProductKey)) {
      isPurchased.value = true;
    }
  }

  /// Registers this device for the account's Pro subscription and refreshes
  /// the entitlements, so [isProEnabledForCurrentDevice] reflects the result.
  /// One call shared by the Registered Devices view, the home banner, the
  /// virtual-shifting notice and the post-purchase dialog. Throws
  /// [DeviceLimitReachedError] when the platform's device limit is reached —
  /// the rider then has to pick a device to revoke.
  Future<void> registerCurrentDevice() async {
    final platform = await deviceManagement.currentPlatform();
    final package = await PackageInfo.fromPlatform();
    await deviceManagement.registerCurrentDevice(
      deviceName: 'BikeControl ${platform?.toUpperCase() ?? ''}',
      appVersion: package.version,
    );
    await entitlements.refresh(force: true);
  }

  /// [featureName] names the gated feature in the upgrade dialog — see
  /// [showGoProDialog]. The app is free now, so every feature is unlocked and
  /// this always succeeds without prompting for a purchase.
  Future<bool> ensureProForFeature(
    BuildContext context, {
    bool isAllowedForOldPurchases = false,
    String? featureName,
  }) async {
    return true;
  }

  void setWinBoughtBefore50() {
    _windowsIapService?.setBoughtBefore50();
  }
}
