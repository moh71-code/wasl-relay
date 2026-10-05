import 'package:flutter/material.dart';
import '../l10n/s.dart';
import 'wasl_theme.dart';

/// WASL logo — a green circle containing the letter "و"
class WaslLogo extends StatelessWidget {
  final double size;
  const WaslLogo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: WaslColors.primary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        'و',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.5,
          fontWeight: FontWeight.bold,
          height: 1.1,
        ),
      ),
    );
  }
}

/// "Encrypted" badge shown in the app header
class EncryptedBadge extends StatelessWidget {
  const EncryptedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? WaslColors.primary.withValues(alpha: 0.25)
            : WaslColors.accent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock,
              size: 11,
              color: isDark ? WaslColors.darkPrimary : WaslColors.primary),
          const SizedBox(width: 4),
          Text(
            S.encryptedBadge,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? WaslColors.darkPrimary : WaslColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular initials avatar with a soft tinted background
class WaslAvatar extends StatelessWidget {
  final Color color;
  final String initials;
  final double size;
  const WaslAvatar({
    super.key,
    required this.color,
    required this.initials,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Text(
        initials,
        style: TextStyle(
          color: color,
          fontSize: size * 0.38,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Animated screen entrance (fade + slight slide)
class ScreenIn extends StatelessWidget {
  final Widget child;
  const ScreenIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: WaslMotion.screenIn,
      curve: WaslMotion.ease,
      builder: (context, v, child) => Transform.translate(
        offset: Offset(-14 * (1 - v), 0),
        child: Opacity(opacity: v, child: child),
      ),
      child: child,
    );
  }
}

/// Animated message bubble entrance (fade + slight rise)
class MessageIn extends StatelessWidget {
  final Widget child;
  const MessageIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: WaslMotion.messageIn,
      curve: WaslMotion.ease,
      builder: (context, v, child) => Transform.translate(
        offset: Offset(0, 6 * (1 - v)),
        child: Transform.scale(
          scale: 0.98 + 0.02 * v,
          child: Opacity(opacity: v, child: child),
        ),
      ),
      child: child,
    );
  }
}

/// Round icon button used in the composer (send / mic / attach)
class WaslRoundIconButton extends StatelessWidget {
  final IconData icon;
  final bool filled;
  final VoidCallback? onTap;
  const WaslRoundIconButton({
    super.key,
    required this.icon,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: filled
          ? WaslColors.primary
          : (isDark ? WaslColors.darkMuted : WaslColors.muted),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(
            icon,
            size: 20,
            color: filled
                ? Colors.white
                : (isDark
                    ? WaslColors.darkMutedForeground
                    : WaslColors.mutedForeground),
          ),
        ),
      ),
    );
  }
}
