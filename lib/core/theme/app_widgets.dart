import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart';

/// Professional UI Components for WASL Premium Messenger
class AppWidgets {
  // Premium Card with gradient and shadow
  static Widget premiumCard({
    required Widget child,
    VoidCallback? onTap,
    EdgeInsetsGeometry? padding,
    bool elevated = false,
  }) {
    return Container(
      padding: padding ?? const EdgeInsets.all(AppTheme.spacingMedium),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        boxShadow: elevated ? AppTheme.elevatedShadow : AppTheme.cardShadow,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        child: child,
      ),
    );
  }
  
  // Gradient Button
  static Widget gradientButton({
    required String text,
    VoidCallback? onPressed,
    Gradient? gradient,
    IconData? icon,
    bool isLoading = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: gradient ?? AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : onPressed,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingLarge,
              vertical: AppTheme.spacingMedium,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                else if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: AppTheme.spacingSmall),
                ],
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  // Premium Avatar
  static Widget premiumAvatar({
    required String name,
    double size = 40,
    Color? backgroundColor,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(size / 2),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.4,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
  
  // Status Indicator
  static Widget statusIndicator({
    required bool isOnline,
    double size = 12,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isOnline ? AppTheme.successColor : AppTheme.textTertiary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }
  
  // Premium Badge
  static Widget premiumBadge({
    required String text,
    Color? color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingSmall,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: color ?? AppTheme.primaryColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
  
  // Shimmer Loading Effect
  static Widget shimmerLoading({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppTheme.dividerColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
    );
  }
  
  // Empty State Widget
  static Widget emptyState({
    required IconData icon,
    required String title,
    required String description,
    String? actionText,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXLarge),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 80,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: AppTheme.spacingMedium),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppTheme.spacingSmall),
            Text(
              description,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionText != null && onAction != null) ...[
              const SizedBox(height: AppTheme.spacingLarge),
              AppWidgets.gradientButton(
                text: actionText,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  // Premium Divider
  static Widget premiumDivider({double? height}) {
    return Container(
      height: height ?? 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            AppTheme.dividerColor,
            Colors.transparent,
          ],
        ),
      ),
    );
  }
  
  // Secure Indicator
  static Widget secureIndicator({bool isEncrypted = true}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isEncrypted ? Icons.lock : Icons.lock_open,
          size: 16,
          color: isEncrypted ? AppTheme.successColor : AppTheme.warningColor,
        ),
        const SizedBox(width: 4),
        Text(
          isEncrypted ? 'E2EE' : 'Unsecured',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: isEncrypted ? AppTheme.successColor : AppTheme.warningColor,
          ),
        ),
      ],
    );
  }
  
  // Premium TextField
  static Widget premiumTextField({
    required TextEditingController controller,
    required String labelText,
    String? hintText,
    IconData? prefixIcon,
    IconData? suffixIcon,
    VoidCallback? onSuffixIconPressed,
    bool obscureText = false,
    String? errorText,
    TextInputType? keyboardType,
    Function(String)? onChanged,
    int? maxLength,
    bool autofocus = false,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: onChanged,
      maxLength: maxLength,
      autofocus: autofocus,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon, color: AppTheme.primaryColor) : null,
        suffixIcon: suffixIcon != null
            ? IconButton(
                icon: Icon(suffixIcon),
                onPressed: onSuffixIconPressed,
              )
            : null,
        errorText: errorText,
      ),
    );
  }
  
  // Connection Status Widget
  static Widget connectionStatus({required String status}) {
    Color statusColor;
    IconData statusIcon;
    
    switch (status.toLowerCase()) {
      case 'connected':
        statusColor = AppTheme.successColor;
        statusIcon = Icons.cloud_done;
        break;
      case 'connecting':
        statusColor = AppTheme.warningColor;
        statusIcon = Icons.cloud_sync;
        break;
      default:
        statusColor = AppTheme.errorColor;
        statusIcon = Icons.cloud_off;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingSmall,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: 4),
          Text(
            status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }
}
