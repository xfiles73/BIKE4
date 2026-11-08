# DEPLOY GitHub (procedura attuale)
1. Caricare i file corretti ALLA RADICE del repo xfiles73/BIKE (branch main), sovrascrivendo.
   Eliminare dal repo, se ancora presenti: work/, bikecontrol_free_deploy_v*.zip,
   pubspec_overrides.yaml, e il pacchetto smtc_windows (gia' rimosso da pubspec.yaml).
2. Settings -> Actions -> Workflow permissions: Read and write.
3. Run workflow "Build & Release" (o push). Attendere: pub get OK, niente errore cargokit.
4. Download Release: bike_control.windows.zip -> BikeControl.exe.
5. Test hardware: Elite Direto XR (FTMS/CPS), telemetria + Virtual Shifting.
   Zwift desktop: via TCP/DirCon o smartphone ponte (BLE peripheral nativo Windows non supportato).

# TROUBLESHOOTING CI
- 'could not find package prop at "prop"' -> workflow vecchio/file obsoleti sul repo.
- 'universal_ble changes vs main forbidden' -> ref devono coincidere (usare changes).
- 'Failed parsing lock file: resolved-ref must be a string' -> blocco git nel lock senza
  resolved-ref; oppure cancellare pubspec.lock e lasciar rigenerare a pub get.
- dart2js 'dart:ffi not available' -> web.yml deve restare disattivato.
- Get-Item C:\Users\runneradmin\AppData (cargokit resolve_symlinks.ps1) -> causato dal plugin
  smtc_windows. RISOLTO rimuovendo smtc_windows da pubspec.yaml e usando lib/utils/smtc_stub.dart.

# STATO ATTUALE (v22 - fix MSB3073 INSTALL.vcxproj windows_iap + native assets)
- Errore CI: cmake install() fallito (MSB3073 su INSTALL.vcxproj). Due cause:
  1. plugin nativo windows_iap (NuGet CppWinRT / install projections) -> rimosso dalla
     build Windows: generato via stub Dart lib/utils/iap/windows_iap_noop.dart; voci
     tolte da windows/flutter/generated_plugins.cmake e generated_plugin_registrant.cc.
     Il pacchetto dart windows_iap resta in pubspec SOLO per i tipi platform-interface.
  2. install(DIRECTORY native_assets/windows/) hard-fails se la dir non esiste su runner
     pulito -> windows/CMakeLists.txt usa ora install(CODE ...) con guardia if(EXISTS).
- Precedente v21 (fix sezione "PER RAPPORTO" bianca): curva rapporti seedata con
  defaultGearRatiosFor(13), resize sicuro in setMaxGear/setGearRatios, guardie difensive
  nelle righe e in _hintFor. Campi coefficiente ora TextBox numerici editabili su desktop;
  indici marce 1-based -> 0-based; lunghezza curva sincronizzata con maxGear.
- File v22 da sostituire: pubspec.yaml, windows/CMakeLists.txt,
  windows/flutter/generated_plugins.cmake, windows/flutter/generated_plugin_registrant.cc,
  lib/utils/iap/windows_iap_noop.dart (nuovo), lib/utils/iap/windows_iap_service.dart,
  lib/pages/proxy_device_details/gear_ratios_editor_page.dart,
  prop_public/lib/emulators/definitions/fitness_bike_definition.dart.
- Storico (gia' nel repo): v19 null-safety/types; v20 rimozione smtc_windows + cargokit
  Get-Item risolto, onReadRequest Future<Uint8List>?, BleCharacteristic 3 argomenti,
  firstWhereOrNull sostituito, overlay_state TrainerMode orElse simMode.
- Fonte canonica: albero di lavoro alla radice (/workspace). work/, tutti gli zip di
  deploy (v11..v21) eliminati dal repo. Gli zip locali sono ignorati (.gitignore *.zip).
