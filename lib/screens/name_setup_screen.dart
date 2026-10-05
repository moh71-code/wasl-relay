import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import '../core/storage/storage_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/wasl_theme.dart';
import '../core/theme/app_widgets.dart';
import '../core/theme/app_animations.dart';

/// First-run screen that asks the user for a display name. The name is sent
/// inside the signed pairing payload so peers see it once a session is paired.
class NameSetupScreen extends StatefulWidget {
  final VoidCallback onDone;

  const NameSetupScreen({super.key, required this.onDone});

  @override
  State<NameSetupScreen> createState() => _NameSetupScreenState();
}

class _NameSetupScreenState extends State<NameSetupScreen> with TickerProviderStateMixin {
  final TextEditingController _nameController = TextEditingController();
  bool _saving = false;
  String? _error;
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _controller.forward();
  }
  
  @override
  void dispose() {
    _nameController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.length < 2) {
      setState(() => _error = S.nameTooShort);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await StorageService().saveDisplayName(name);
    if (!mounted) return;
    widget.onDone();
  }
  
  void _handleSave() {
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.primaryColor.withValues(alpha: 0.1),
              AppTheme.surfaceColor,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppTheme.spacingXLarge),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return AppAnimations.fadeSlideIn(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Premium Icon
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            gradient: AppTheme.primaryGradient,
                            borderRadius: BorderRadius.circular(25),
                            boxShadow: AppTheme.elevatedShadow,
                          ),
                          child: const Icon(
                            Icons.badge_rounded,
                            size: 50,
                            color: Colors.white,
                          ),
                        ),
                        
                        const SizedBox(height: AppTheme.spacingLarge),
                        
                        // Title
                        Text(
                          S.welcome,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall?.copyWith(
                            color: AppTheme.primaryColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: AppTheme.spacingMedium),

                        // Description
                        Text(
                          S.nameSetupHint,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: WaslColors.mutedFg(context),
                            height: 1.5,
                          ),
                        ),
                        
                        const SizedBox(height: AppTheme.spacingXLarge),
                        
                        // Name Input Card
                        AppWidgets.premiumCard(
                          elevated: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.yourDisplayName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: WaslColors.fg(context),
                                ),
                              ),
                              const SizedBox(height: AppTheme.spacingMedium),
                              TextField(
                                controller: _nameController,
                                maxLength: 30,
                                textCapitalization: TextCapitalization.words,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: S.nameExample,
                                  prefixIcon: const Icon(Icons.person_rounded),
                                  counterText: '',
                                  errorText: _error,
                                ),
                                onSubmitted: (_) => _save(),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: AppTheme.spacingSmall),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.error_outline,
                                      size: 16,
                                      color: AppTheme.errorColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        _error!,
                                        style: TextStyle(
                                          color: AppTheme.errorColor,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: AppTheme.spacingLarge),
                        
                        // Continue Button
                        SizedBox(
                          height: 56,
                          child: AppWidgets.gradientButton(
                            text: S.continueBtn,
                            icon: Icons.arrow_forward_rounded,
                            onPressed: _saving ? null : _handleSave,
                            isLoading: _saving,
                          ),
                        ),
                        
                        const SizedBox(height: AppTheme.spacingMedium),
                        
                        // Privacy Note
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.privacy_tip_outlined,
                              size: 16,
                              color: WaslColors.mutedFg(context),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              S.privacyFirst,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: WaslColors.mutedFg(context),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
