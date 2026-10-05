import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/database/database_helper.dart';
import '../core/storage/storage_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/wasl_theme.dart';
import '../core/theme/app_widgets.dart';
import '../providers/settings_provider.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _userId;

  @override
  void initState() {
    super.initState();
    StorageService().getUserId().then((id) {
      if (mounted) setState(() => _userId = id);
    });
  }

  /// Clears every chat's messages and media while keeping contacts,
  /// groups, pairings and identity fully intact.
  void _showClearChatsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.cleaning_services_outlined,
                  color: Colors.orange, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(S.clearChatContent)),
          ],
        ),
        content: Text(S.clearChatContentWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.cancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await DatabaseHelper.instance.clearAllChatHistory();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(S.chatsCleared)),
              );
            },
            child: Text(S.delete),
          ),
        ],
      ),
    );
  }

  void _showZeroizeDialog(BuildContext context, SettingsProvider settings) {
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.errorColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.warning_amber_rounded, color: AppTheme.errorColor, size: 20),
            ),
            const SizedBox(width: 12),
                  Text(S.secureWipe),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppWidgets.premiumCard(
              child: Column(
                children: [
                  const Icon(
                    Icons.delete_forever_rounded,
                    size: 48,
                    color: AppTheme.errorColor,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.secureWipeWarning,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: WaslColors.mutedFg(context),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.errorColor.withValues(alpha: 0.3)),
                    ),
                    child:       Row(
                      children: [
                        Icon(Icons.info_outline, color: AppTheme.errorColor, size: 16),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            S.areYouSure,
                            style: TextStyle(
                              color: AppTheme.errorColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:       Text(S.cancel),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.errorColor, Color(0xFFDC2626)],
              ),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            ),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: AppTheme.errorColor),
                        const SizedBox(height: 16),
                              Text(
                          S.wipingData,
                          style: TextStyle(color: WaslColors.mutedFg(context)),
                        ),
                      ],
                    ),
                  ),
                );

                await settings.performSecureZeroize();

                if (context.mounted) {
                  Navigator.pop(context); // Close progress dialog
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (route) => false,
                  );
                }
              },
              child:       Text(S.wipeEverything, style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  void _showDisplayNameDialog(BuildContext context, SettingsProvider settings) {
    final pageContext = context;
    final controller = TextEditingController(text: settings.displayName ?? '');
    String? error;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.badge_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
                    Text(S.displayName),
            ],
          ),
          content: AppWidgets.premiumTextField(
            controller: controller,
            labelText: S.displayNameHint,
            prefixIcon: Icons.person_rounded,
            errorText: error,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:       Text(S.cancel),
            ),
            AppWidgets.gradientButton(
              text: S.save,
              onPressed: () async {
                final name = controller.text.trim();
                if (name.length < 2) {
                  setDlgState(
                      () => error = S.nameMinChars);
                  return;
                }
                await settings.saveDisplayName(name);
                if (ctx.mounted) Navigator.pop(ctx);
                if (pageContext.mounted) {
                  ScaffoldMessenger.of(pageContext).showSnackBar(
                    SnackBar(
                      content:       Text(S.nameSaved),
                      backgroundColor: AppTheme.successColor,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Generic numeric PIN entry dialog; returns the entered code or null on cancel.
  Future<String?> _promptPin(
    BuildContext context, {
    required SettingsProvider settings,
    required String title,
    String? subtitle,
  }) {
    final controller = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.lock_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Text(title),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      subtitle,
                      style: const TextStyle(height: 1.4),
                      textAlign: TextAlign.center,
                    ),
                  ),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  autofocus: true,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  decoration: InputDecoration(
                    labelText: S.pinDigits,
                    errorText: error,
                    prefixIcon: const Icon(Icons.pin_rounded, color: AppTheme.primaryColor),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child:       Text(S.cancel),
              ),
              AppWidgets.gradientButton(
                text: S.confirm,
                onPressed: () {
                  final pin = controller.text.trim();
                  if (pin.length < 4 || pin.length > 6) {
                    setDlgState(
                        () => error = S.pinLengthError);
                    return;
                  }
                  Navigator.pop(ctx, pin);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _enablePinFlow(BuildContext context, SettingsProvider settings) async {
    final pin = await _promptPin(
      context,
      settings: settings,
      title: S.createPin,
      subtitle: S.createPinHint,
    );
    if (pin == null || !context.mounted) return;
    final confirm = await _promptPin(
      context,
      settings: settings,
      title: S.confirmPin,
    );
    if (confirm == null) return;
    if (pin != confirm) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:       Text(S.pinsDontMatch),
            backgroundColor: AppTheme.errorColor,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final ok = await settings.enablePinLock(pin);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? S.pinEnabled
              : S.pinEnableFailed),
          backgroundColor: ok ? AppTheme.successColor : AppTheme.errorColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _changePinFlow(BuildContext context, SettingsProvider settings) async {
    final current = await _promptPin(
      context,
      settings: settings,
      title: S.changePin,
      subtitle: S.enterCurrentPin,
    );
    if (current == null || !context.mounted) return;
    final newPin = await _promptPin(
      context,
      settings: settings,
      title: S.newPin,
    );
    if (newPin == null || !context.mounted) return;
    final confirm = await _promptPin(
      context,
      settings: settings,
      title: S.confirmNewPin,
    );
    if (confirm == null) return;
    if (newPin != confirm) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:       Text(S.pinsDontMatch),
            backgroundColor: AppTheme.errorColor,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final ok = await settings.changePin(current, newPin);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? S.pinChanged
              : S.currentPinWrong),
          backgroundColor: ok ? AppTheme.successColor : AppTheme.errorColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _disablePinFlow(BuildContext context, SettingsProvider settings) async {
    final pin = await _promptPin(
      context,
      settings: settings,
      title: S.disablePinLock,
      subtitle: S.enterCurrentToConfirm,
    );
    if (pin == null) return;
    final ok = await settings.disablePinLock(pin);
    if (context.mounted && !ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:       Text(S.pinStillEnabled),
          backgroundColor: AppTheme.errorColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _autoLockLabel(int seconds) {
    if (seconds == 0) return S.immediately;
    if (seconds < 60) return S.afterSeconds(seconds);
    final mins = seconds ~/ 60;
    return mins == 1 ? S.afterOneMinute : S.afterMinutes(mins);
  }

  Future<void> _pickAutoLockDelay(BuildContext context, SettingsProvider settings) async {
    const options = [0, 30, 60, 300, 1800, 3600];
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
                    Text(
                S.autoLock,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              RadioGroup<int>(
                groupValue: settings.autoLockSeconds,
                onChanged: (v) => Navigator.pop(ctx, v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: options
                      .map((s) => RadioListTile<int>(
                            value: s,
                            title: Text(_autoLockLabel(s)),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await settings.setAutoLockSeconds(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isAr = settings.isArabic;
    final theme = Theme.of(context);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Premium App Bar
          SliverAppBar(
            expandedHeight: 120,
            floating: false,
            pinned: true,
            elevation: 0,
            backgroundColor: AppTheme.primaryColor,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.spacingLarge),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.settings_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                            const SizedBox(width: 12),
                                  Text(
                              S.privacyAndSettings,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 24,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // Content
          SliverToBoxAdapter(
            child: ListView(
              padding: const EdgeInsets.all(AppTheme.spacingMedium),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // Section 1: Anonymous Identity
                if (_userId != null) ...[
                  _buildSectionHeader(S.anonymousIdentity),
                  const SizedBox(height: AppTheme.spacingSmall),
                  
                  AppWidgets.premiumCard(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                gradient: AppTheme.primaryGradient,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.fingerprint_rounded, color: Colors.white),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.deviceCryptoId,
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      color: WaslColors.mutedFg(context),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    _userId!,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: AppTheme.primaryColor,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy_all_rounded),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _userId!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content:       Text(S.cryptoIdCopied),
                                    backgroundColor: AppTheme.successColor,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: AppTheme.spacingMedium),
                  
                  AppWidgets.premiumCard(
                    onTap: () => _showDisplayNameDialog(context, settings),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: AppTheme.accentGradient,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.badge_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.displayName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                settings.displayName ?? S.notSetYet,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: WaslColors.mutedFg(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: WaslColors.mutedFg(context)),
                      ],
                    ),
                  ),
                  
                  AppWidgets.premiumDivider(),
                ],
                
                // Section 3: Privacy & Security Preferences
                _buildSectionHeader(S.privacyAndData),
                const SizedBox(height: AppTheme.spacingSmall),

                AppWidgets.premiumCard(
                  child: Column(
                    children: [
                      _buildSettingTile(
                        icon: Icons.done_all_rounded,
                        title: S.readReceipts,
                        subtitle: S.readReceiptsHint,
                        trailing: Switch(
                          value: settings.sendReadReceipts,
                          activeThumbColor: AppTheme.primaryColor,
                          onChanged: (val) => settings.setReadReceipts(val),
                        ),
                      ),
                      AppWidgets.premiumDivider(),
                      _buildSettingTile(
                        icon: Icons.download_for_offline_rounded,
                        title: S.autoDownloadMedia,
                        subtitle: S.autoDownloadHint,
                        trailing: Switch(
                          value: settings.autoDownloadMedia,
                          activeThumbColor: AppTheme.primaryColor,
                          onChanged: (val) => settings.setAutoDownloadMedia(val),
                        ),
                      ),
                    ],
                  ),
                ),
                
                AppWidgets.premiumDivider(),
                
                // Section 4: App PIN Lock
                _buildSectionHeader(S.pinLock),
                const SizedBox(height: AppTheme.spacingSmall),

                AppWidgets.premiumCard(
                  child: Column(
                    children: [
                      _buildSettingTile(
                        icon: Icons.lock_rounded,
                        title: S.pinLockTitle,
                        subtitle: settings.pinLockEnabled
                            ? S.pinLockOn
                            : S.pinLockOff,
                        trailing: Switch(
                          value: settings.pinLockEnabled,
                          activeThumbColor: AppTheme.primaryColor,
                          onChanged: (val) async {
                            if (val) {
                              await _enablePinFlow(context, settings);
                            } else {
                              await _disablePinFlow(context, settings);
                            }
                          },
                        ),
                      ),
                      if (settings.pinLockEnabled) ...[
                        AppWidgets.premiumDivider(),
                        _buildSettingTile(
                          icon: Icons.pin_rounded,
                          title: S.changePin,
                          onTap: () => _changePinFlow(context, settings),
                        ),
                        AppWidgets.premiumDivider(),
                        _buildSettingTile(
                          icon: Icons.timer_rounded,
                          title: S.autoLock,
                          subtitle: _autoLockLabel(settings.autoLockSeconds),
                          onTap: () => _pickAutoLockDelay(context, settings),
                        ),
                      ],
                    ],
                  ),
                ),
                
                AppWidgets.premiumDivider(),
                
                // Section 5: Appearance & Language
                _buildSectionHeader(S.appearanceAndLang),
                const SizedBox(height: AppTheme.spacingSmall),

                AppWidgets.premiumCard(
                  child: Column(
                    children: [
                      _buildSettingTile(
                        icon: Icons.dark_mode_rounded,
                        title: S.darkMode,
                        trailing: Switch(
                          value: settings.themeMode == ThemeMode.dark,
                          activeThumbColor: AppTheme.primaryColor,
                          onChanged: (val) => settings.toggleTheme(val),
                        ),
                      ),
                      AppWidgets.premiumDivider(),
                      _buildSettingTile(
                        icon: Icons.language_rounded,
                        title: S.appLanguage,
                        subtitle: isAr ? 'العربية' : 'English',
                        trailing: DropdownButton<String>(
                          value: settings.locale.languageCode,
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 'ar', child: Text('العربية')),
                            DropdownMenuItem(value: 'en', child: Text('English')),
                          ],
                          onChanged: (lang) {
                            if (lang != null) settings.changeLanguage(lang);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                
                AppWidgets.premiumDivider(),
                
                // Section 6: Clear chat content (keeps contacts & groups)
                AppWidgets.premiumCard(
                  onTap: () => _showClearChatsDialog(context),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.cleaning_services_outlined,
                            color: Colors.orange, size: 20),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.clearChatContent,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.orange,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              S.clearChatContentHint,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: WaslColors.mutedFg(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          color: WaslColors.mutedFg(context)),
                    ],
                  ),
                ),

                AppWidgets.premiumDivider(),

                // Section 6b: Secure Data Wipe
                AppWidgets.premiumCard(
                  onTap: () => _showZeroizeDialog(context, settings),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.errorColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.delete_forever_rounded, color: AppTheme.errorColor, size: 20),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.wipeLocalData,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: AppTheme.errorColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              S.wipeLocalDataHint,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: WaslColors.mutedFg(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: WaslColors.mutedFg(context)),
                    ],
                  ),
                ),
                
                const SizedBox(height: AppTheme.spacingXLarge),
                
                // Version Info
                Center(
                  child: Column(
                    children: [
                      AppWidgets.premiumBadge(text: S.version),
                      const SizedBox(height: 8),
                      Text(
                        S.tagline,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: WaslColors.mutedFg(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingSmall),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: AppTheme.primaryColor,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
  
  Widget _buildSettingTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: AppTheme.spacingSmall,
          horizontal: AppTheme.spacingSmall,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: AppTheme.primaryColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: WaslColors.mutedFg(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }
}
