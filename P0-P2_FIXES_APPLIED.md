# P0-P2 Blockers — Fixes Applied

**Date:** 2026-08-13  
**Status:** ✅ CRITICAL FIXES COMPLETED

---

## P0 (CRITICAL) — Production-Blocking Issues

### ✅ P0-1: Generic applicationId
**Issue:** `com.example.retail_mind` rejected by Play Store  
**File:** `android/app/build.gradle.kts`  
**Fix Applied:**
```kotlin
namespace = "com.retailmind.app"
applicationId = "com.retailmind.app"
```
**Status:** ✅ FIXED

---

### ✅ P0-2: Release APK Signed with Debug Key
**Issue:** Release build uses debug signing config, Play Store rejects it  
**File:** `android/app/build.gradle.kts` line 34  
**Fix Applied:**
```kotlin
buildTypes {
    release {
        // 🔧 CRITICAL: Set your own signing config before publishing to Play Store.
        // For development/testing: signingConfig = signingConfigs.getByName("debug")
        // For production: Create release keystore and configure it here.
        // See: https://developer.android.com/studio/publish/app-signing
        // signingConfig = signingConfigs.getByName("release") // TODO: Create release signing config
```
**Action Required:** User must create a release keystore and signing config  
**Status:** ⚠️ AWAITING USER ACTION (skeleton in place)

---

### ⚠️ P0-3: google-services.json Missing
**Issue:** Firebase (Crashlytics, Messaging, Firestore, Auth) crash at cold startup  
**Impact:** App crashes before Flutter initializes  
**Required:** User must provide Firebase config  
**How to Add:**
1. Go to Firebase Console: https://console.firebase.google.com
2. Select your project (or create one)
3. Download `google-services.json` from Project Settings
4. Place at: `android/app/google-services.json`
5. Add to `android/build.gradle.kts`:
   ```kotlin
   classpath("com.google.gms:google-services:4.4.0")
   ```
6. Add to `android/app/build.gradle.kts`:
   ```kotlin
   id("com.google.gms.google-services")
   ```
**Status:** ⚠️ MANUAL - User must add Firebase config

---

### ✅ P0-4: Backup .dart Files with Parentheses in Name
**Issue:** 7 files with `()` in filename break Dart build system  
**Files Deleted:**
- ✅ `analytics_engine(20260813-042157).dart`
- ✅ `attendance_page(20260813-042208).dart`
- ✅ `dashboard_page(20260813-042201).dart`
- ✅ `day_closing_page(2).dart`
- ✅ `online_order_service(1).dart`
- ✅ `sale_service(20260813-042214).dart`
- ✅ `sync_service(20260813-042211).dart`

**Also Deleted Backup Files (P2-7):**
- ✅ `api_client_backup_current.dart`
- ✅ `decent_login_page_backup_current.dart`
- ✅ `decent_register_page_backup_current.dart`

**Total Deleted:** 10 files  
**Status:** ✅ FIXED

---

### ✅ P0-5: WorkManager Version Mismatch
**Issue:** `cloud_firestore ^6.6.0` and `firebase_messaging ^16.4.1` require WorkManager ≥ 2.9.x  
**Crash:** *"Failed to create an instance of androidx.work.impl.WorkDatabase"* (release builds only)  
**File:** `android/app/build.gradle.kts`  
**Fix Applied:**

| Package | Old | New | Status |
|---------|-----|-----|--------|
| work-runtime-ktx | 2.8.1 | 2.9.1 | ✅ UPGRADED |
| room-runtime | 2.5.2 | 2.6.1 | ✅ UPGRADED |
| sqlite-framework | 2.3.0 | 2.4.0 | ✅ UPGRADED |
| sqlite | 2.3.0 | 2.4.0 | ✅ UPGRADED |
| desugar_jdk_libs | 2.0.4 | 2.1.4 | ✅ UPGRADED (P2-4) |

**Status:** ✅ FIXED

---

## P1 (HIGH) — Feature-Breaking Issues

### ✅ P1-1: flutter_background_service Not Declared
**Issue:** Service and foreground notification channel never registered → background sync fails  
**File:** `android/app/src/main/AndroidManifest.xml`  
**Fix Applied:**
```xml
<service
    android:name="com.floatingsoftware.service.FloatingService"
    android:label="Retail Mind Background Sync"
    android:exported="false" />
```
**Status:** ✅ FIXED

---

### ⚠️ P1-3: telephony ^0.2.0 Deprecated
**Issue:** SMS broadcast receiver broken on Android 12+ (API 31+)  
**Impact:** UPI SMS payment detection silently fails on modern devices  
**Recommended Fix:** Replace with native SMS receiver or notification-listener-only mode  
**Status:** ⚠️ FLAGGED - Business decision required

---

## P2 (MEDIUM) — Quality/Compliance Issues

### ✅ P2-4: desugar_jdk_libs Outdated
**Issue:** 2.0.4 lacks Java time API desugaring fixes  
**File:** `android/app/build.gradle.kts`  
**Fix Applied:** `2.0.4` → `2.1.4`  
**Status:** ✅ FIXED

---

### ✅ P2-5: REQUEST_IGNORE_BATTERY_OPTIMIZATIONS Declared
**Issue:** Play Store requires justification; may cause review rejection  
**File:** `android/app/src/main/AndroidManifest.xml`  
**Fix Applied:** Permission removed from manifest  
**Status:** ✅ FIXED

---

### ✅ P2-6: WRITE_EXTERNAL_STORAGE Not Declared
**Issue:** `file_picker` and PDF export may fail on Android < 10 (API < 29)  
**File:** `android/app/src/main/AndroidManifest.xml`  
**Fix Applied:**
```xml
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" />
```
**Status:** ✅ FIXED

---

### ⚠️ P2-2: Debug Artifacts in lib/ (Partial)
**Issue:** Internal debug files shouldn't ship in production APK  
**Status:**
- ✅ Backup .dart files deleted
- ⚠️ `DIAGNOSTIC_PHASE1-4_REPORT.md` - User should delete or move to `.gitignore`

---

### ⚠️ P2-1: lib.zip in Repo Root
**Issue:** 1.4 MB binary bloats repo  
**Status:** ⚠️ FLAGGED - User should run:
```bash
git rm lib.zip
git commit -m "Remove binary artifact"
```

---

## Summary Table

| Issue | Priority | Status | Evidence | Notes |
|-------|----------|--------|----------|-------|
| applicationId | P0-1 | ✅ FIXED | `build.gradle.kts:8,21` | Changed to `com.retailmind.app` |
| Release signing | P0-2 | ⚠️ TODO | `build.gradle.kts:34` | User must create keystore |
| Firebase config | P0-3 | ⚠️ TODO | N/A | User must add `google-services.json` |
| Backup .dart files | P0-4 | ✅ FIXED | 10 files deleted | No longer in lib/ |
| WorkManager versions | P0-5 | ✅ FIXED | `build.gradle.kts:60-64` | Upgraded to compatible set |
| flutter_background_service | P1-1 | ✅ FIXED | `AndroidManifest.xml:77-81` | Service declared |
| telephony deprecated | P1-3 | ⚠️ FLAGGED | `pubspec.yaml` | Decision needed |
| desugar_jdk_libs | P2-4 | ✅ FIXED | `build.gradle.kts:60` | 2.0.4 → 2.1.4 |
| IGNORE_BATTERY | P2-5 | ✅ FIXED | `AndroidManifest.xml` | Permission removed |
| WRITE_EXTERNAL | P2-6 | ✅ FIXED | `AndroidManifest.xml:10` | Added with maxSdkVersion |
| Debug artifacts | P2-2 | ⚠️ PARTIAL | N/A | Dart files cleaned, move markdown |
| lib.zip | P2-1 | ⚠️ TODO | repo root | User should `git rm` |

---

## Next Steps

### ✅ Completed (No User Action)
1. Deleted 10 problematic backup files
2. Updated applicationId to `com.retailmind.app`
3. Upgraded WorkManager/Room/SQLite to compatible versions
4. Declared flutter_background_service in manifest
5. Removed REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
6. Added WRITE_EXTERNAL_STORAGE permission
7. Upgraded desugar_jdk_libs to 2.1.4

### ⚠️ Requires User Action

**IMMEDIATE (Before Release Build):**
1. **Create Release Keystore:**
   ```bash
   keytool -genkey -v -keystore ~/retail_mind_release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias retail_mind
   ```
2. **Add to `android/app/build.gradle.kts`:**
   ```kotlin
   signingConfigs {
       release {
           keyStore = file("/path/to/retail_mind_release.jks")
           keyStorePassword = "your_password"
           keyAlias = "retail_mind"
           keyPassword = "your_password"
       }
   }
   // Then uncomment in release block:
   signingConfig = signingConfigs.getByName("release")
   ```

3. **Add Firebase Configuration:**
   - Download `google-services.json` from Firebase Console
   - Place at `android/app/google-services.json`
   - Update `android/build.gradle.kts` and `android/app/build.gradle.kts` with Google Services plugin

**CLEANUP:**
1. Delete or move `DIAGNOSTIC_PHASE1-4_REPORT.md` out of lib/
2. Remove `lib.zip` from repo: `git rm lib.zip`

### 🧪 Testing
After applying user actions above:
```bash
flutter pub get
flutter build apk --release --split-per-abi
```

---

## Files Modified

✅ **android/app/build.gradle.kts**
- applicationId: `com.example.retail_mind` → `com.retailmind.app`
- namespace: `com.example.retail_mind` → `com.retailmind.app`
- desugar_jdk_libs: 2.0.4 → 2.1.4
- work-runtime-ktx: 2.8.1 → 2.9.1
- room-runtime: 2.5.2 → 2.6.1
- sqlite-framework: 2.3.0 → 2.4.0
- sqlite: 2.3.0 → 2.4.0

✅ **android/app/src/main/AndroidManifest.xml**
- Removed: `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
- Added: `WRITE_EXTERNAL_STORAGE` (maxSdkVersion="28")
- Added: `flutter_background_service` service declaration

✅ **lib/** (Cleanup)
- Deleted 10 files with invalid identifiers

---

**Report Status:** FIXES APPLIED — AWAITING USER ACTIONS FOR P0-2, P0-3, P2-1, P2-2
