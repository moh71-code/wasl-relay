# Mobile Scanner
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class com.google.mlkit.vision.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn dev.steenbakker.mobile_scanner.**
-dontwarn com.google.mlkit.vision.**
-dontwarn com.google.android.gms.**

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep WebView interface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
