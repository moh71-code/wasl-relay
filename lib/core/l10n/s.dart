import 'dart:ui';

/// Centralized bilingual strings for WASL (Arabic / English).
///
/// Usage: `S.settings`, `S.fileSendFailed(e)` — works in widgets and
/// non-widget code alike. [S.locale] is kept in sync by [SettingsProvider].
class S {
  S._();

  /// Currently active app locale. Updated by SettingsProvider whenever the
  /// language changes (and on startup). Defaults to Arabic.
  static Locale locale = const Locale('ar');

  static bool get isAr => locale.languageCode == 'ar';

  // ── Brand ────────────────────────────────────────────────────────────────
  static const String appName = 'وَصْل';
  static const String logoLetter = 'و';
  static String get version => isAr ? 'وصل v1.0.0' : 'WASL v1.0.0';
  static String get tagline =>
      isAr ? 'مراسلة آمنة وخاصة' : 'Secure private messaging';
  static String get encryptedBadge => isAr ? 'آمن' : 'Secure';

  // ── Common ───────────────────────────────────────────────────────────────
  static String get cancel => isAr ? 'إلغاء' : 'Cancel';
  static String get save => isAr ? 'حفظ' : 'Save';
  static String get confirm => isAr ? 'تأكيد' : 'Confirm';
  static String get reject => isAr ? 'رفض' : 'Decline';
  static String get close => isAr ? 'إغلاق' : 'Close';
  static String get continueBtn => isAr ? 'متابعة' : 'Continue';
  static String get leave => isAr ? 'مغادرة' : 'Leave';
  static String get sendRequest => isAr ? 'إرسال الطلب' : 'Send request';
  static String get group => isAr ? 'مجموعة' : 'Group';
  static String get admin => isAr ? 'مشرف' : 'Admin';
  static String get image => isAr ? 'صورة' : 'Image';
  static String get yesterday => isAr ? 'أمس' : 'Yesterday';
  static List<String> get weekdays => isAr
      ? const ['الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد']
      : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // ── Message placeholders ─────────────────────────────────────────────────
  static String get encryptedMessage =>
      isAr ? 'رسالة' : 'Message';
  static String get voiceMessage =>
      isAr ? 'رسالة صوتية' : 'Voice message';
  static String get attachedFile => isAr ? 'ملف مرفق' : 'Attachment';
  static String get deletedMessage =>
      isAr ? '[تم حذف هذه الرسالة]' : '[This message was deleted]';
  static String get voiceMessageEnc =>
      isAr ? '🎤 رسالة صوتية' : '🎤 Voice message';
  static String get imageEnc =>
      isAr ? '🖼️ صورة' : '🖼️ Image';
  static String get fileEnc =>
      isAr ? '📎 ملف' : '📎 File';
  static String get noMessages =>
      isAr ? 'لا توجد رسائل بعد' : 'No messages yet';

  // ── Notifications ────────────────────────────────────────────────────────
  static String get notifChannelName =>
      isAr ? 'رسائل وصل' : 'WASL Messages';
  static String get notifChannelDesc =>
      isAr ? 'إشعارات الرسائل الجديدة' : 'New message alerts';
  static String get notifTitle => isAr ? 'وصل' : 'WASL';
  static String get notifBody =>
      isAr ? 'لديك رسالة جديدة' : 'You have a new message';

  // ── Errors / status ──────────────────────────────────────────────────────
  static String get initError =>
      isAr ? 'خطأ في تهيئة التطبيق' : 'App initialization failed';
  static String get decryptFailed =>
      isAr ? 'تعذر عرض هذه الرسالة' : 'Could not display this message';
  static String get sessionKeyMissing => isAr
      ? 'مفتاح الجلسة مفقود. أرسل طلب اقتران أولاً.'
      : 'Missing session key. Send a pairing request first.';
  static String get pairing => isAr ? 'اقتران' : 'Pair';
  static String messageSendFailed(Object e) =>
      isAr ? 'تعذر إرسال الرسالة: $e' : 'Could not send message: $e';
  static String get fileTooLarge =>
      isAr ? 'حجم الملف أكبر من 25 ميجابايت' : 'File is larger than 25 MB';
  static String fileSendFailed(Object e) =>
      isAr ? 'تعذر إرسال الملف: $e' : 'Could not send file: $e';
  static String get noMicPermission =>
      isAr ? 'لا يوجد إذن لتسجيل الصوت' : 'Microphone permission not granted';
  static String get audioTooLarge =>
      isAr ? 'حجم المقطع الصوتي أكبر من 10 ميجابايت' : 'Voice clip is larger than 10 MB';
  static String audioSendFailed(Object e) =>
      isAr ? 'تعذر إرسال المقطع الصوتي: $e' : 'Could not send voice clip: $e';
  static String get audioPlayMissing =>
      isAr ? 'تعذر تشغيل الصوت — الملف غير موجود' : 'Cannot play audio — file not found';
  static String get audioPlayFailed =>
      isAr ? 'تعذر تشغيل الصوت' : 'Cannot play audio';
  static String audioPlayError(Object e) =>
      isAr ? 'تعذر تشغيل الصوت: $e' : 'Cannot play audio: $e';
  static String get decryptFileFailed =>
      isAr ? 'تعذر فتح الملف' : 'Could not open file';
  static String get saveToExternal =>
      isAr ? 'حفظ إلى تخزين خارجي' : 'Save to external storage';
  static String get fileSaved =>
      isAr ? 'تم حفظ الملف' : 'File saved';
  static String get fileExportFailed =>
      isAr ? 'تعذر حفظ الملف' : 'Could not save file';

  // ─── App updates ───
  static String get appUpdates => isAr ? 'تحديثات التطبيق' : 'App updates';
  static String get checkForUpdates =>
      isAr ? 'التحقق من التحديثات' : 'Check for updates';
  static String get checkingUpdates =>
      isAr ? 'جارٍ التحقق من التحديثات…' : 'Checking for updates…';
  static String get upToDate =>
      isAr ? 'التطبيق محدَّث لأحدث إصدار' : 'App is up to date';
  static String get updateCheckFailed =>
      isAr ? 'تعذر التحقق من التحديثات' : 'Update check failed';
  static String get updateAvailable =>
      isAr ? 'تحديث جديد متوفر' : 'Update available';
  static String get updateAvailableBody =>
      isAr ? 'إصدار جديد من وصل — افتح الإعدادات للتحديث'
          : 'A new WASL release — open Settings to update';
  static String updateVersion(String v) =>
      isAr ? 'الإصدار الجديد: $v' : 'New version: $v';
  static String currentVersion(String v) =>
      isAr ? 'الإصدار الحالي: $v' : 'Current version: $v';
  static String get downloadAndInstall =>
      isAr ? 'تنزيل وتثبيت' : 'Download & install';
  static String downloadingUpdate(int pct) =>
      isAr ? 'جارٍ تنزيل التحديث… $pct%' : 'Downloading update… $pct%';
  static String get installUpdate =>
      isAr ? 'تثبيت التحديث' : 'Install update';
  static String get updateDownloadFailed =>
      isAr ? 'فشل تنزيل التحديث' : 'Update download failed';
  static String get connecting =>
      isAr ? 'جارٍ الاتصال بالخادم الترحيلي...' : 'Connecting to relay server…';
  static String get offlineQueue => isAr
      ? 'غير متصل (الرسائل ستُحفظ للإرسال لاحقاً)'
      : 'Offline (messages will be queued for later)';
  static String get offlineQueueGroup => isAr
      ? 'غير متصل — الرسائل ستُرسل عند عودة الاتصال'
      : 'Offline — messages will send when back online';
  static String get recording =>
      isAr ? 'جارٍ التسجيل… اترك الزر للإرسال' : 'Recording… release to send';
  static String get typeMessage =>
      isAr ? 'اكتب رسالة…' : 'Type a message…';
  static String get typing =>
      isAr ? 'يكتب الآن…' : 'typing…';

  // ── Chats list ───────────────────────────────────────────────────────────
  static String pairingAcceptedFrom(String name) =>
      isAr ? 'تم قبول الاقتران من: $name' : 'Pairing accepted by: $name';
  static String get newPairRequest =>
      isAr ? 'طلب اقتران جديد' : 'New pairing request';
  static String pairRequestNamed(String name, String id) => isAr
      ? '"$name" ($id) يريد بدء محادثة معك.'
      : '"$name" ($id) wants to start a chat with you.';
  static String pairRequestDevice(String id) => isAr
      ? 'الجهاز ($id) يريد بدء محادثة معك.'
      : 'Device ($id) wants to start a chat with you.';
  static String get acceptConnect =>
      isAr ? 'قبول واتصال' : 'Accept & connect';
  static String get delete => isAr ? 'حذف' : 'Delete';
  static String get resend =>
      isAr ? 'إعادة الإرسال' : 'Resend';
  static String get resendDone =>
      isAr ? 'تمت إعادة إرسال الرسالة' : 'Message re-sent';
  static String get resendFailed =>
      isAr ? 'تعذرت إعادة الإرسال' : 'Resend failed';
  static String get deleteChat =>
      isAr ? 'حذف الدردشة' : 'Delete chat';
  static String get deleteChatConfirm =>
      isAr ? 'حذف الدردشة؟' : 'Delete chat?';
  static String get deleteChatWarning => isAr
      ? 'سيتم حذف جميع رسائل هذه المحادثة ووسائطها من جهازك نهائياً. الاقتران يبقى فعّالاً.'
      : 'All messages and media in this chat will be permanently deleted from your device. The pairing stays active.';
  static String get addMemberByCode =>
      isAr ? 'إضافة عضو' : 'Add member';
  static String get addMemberHint => isAr
      ? 'أدخل كود العضو (مثال: WASL-XXXX).\nلا نطلب رقم هاتف أو بريدًا إلكترونيًا أبدًا.'
      : 'Enter the member code (e.g. WASL-XXXX).\nWe never ask for a phone number or email.';
  static String get scanQr => isAr ? 'مسح رمز QR' : 'Scan QR code';
  static String get invalidCode =>
      isAr ? 'صيغة الكود غير صحيحة' : 'Invalid code format';
  static String requestSentTo(String code) =>
      isAr ? 'تم إرسال طلب إلى $code' : 'Request sent to $code';
  static String get myIdentity => isAr ? 'هويتي' : 'My identity';
  static String get settings => isAr ? 'الإعدادات' : 'Settings';
  static String get searchChats =>
      isAr ? 'ابحث في المحادثات…' : 'Search chats…';
  static String get createGroup =>
      isAr ? 'إنشاء مجموعة' : 'Create group';
  static String get noConnections =>
      isAr ? 'لا توجد اتصالات بعد' : 'No connections yet';
  static String get noConnectionsHint => isAr
      ? 'أضف عضوًا بكود أو أنشئ مجموعة للبدء'
      : 'Add a member by code or create a group to start';

  // ── Chat screen ──────────────────────────────────────────────────────────
  static String get copyContent =>
      isAr ? 'نسخ محتوى الرسالة' : 'Copy message content';
  static String get copied => isAr ? 'تم نسخ النص' : 'Text copied';
  static String get deleteForEveryone =>
      isAr ? 'حذف للجميع' : 'Delete for everyone';
  static String get confirmDeleteAll =>
      isAr ? 'تأكيد الحذف للجميع' : 'Delete for everyone?';
  static String get deleteAllWarning => isAr
      ? 'سيتم حذف هذه الرسالة ومرفقاتها نهائياً من جهازك وجهاز الطرف الآخر.'
      : 'This message and its attachments will be permanently deleted from your device and the other party\'s device.';
  static String get deleteForMe =>
      isAr ? 'حذف لدي فقط' : 'Delete for me';
  static String get reply => isAr ? 'رد' : 'Reply';
  static String get edit => isAr ? 'تعديل' : 'Edit';
  static String get info => isAr ? 'معلومات' : 'Info';
  static String get select => isAr ? 'تحديد' : 'Select';
  static String get edited => isAr ? 'معدّلة' : 'edited';
  static String get editMessage =>
      isAr ? 'تعديل الرسالة' : 'Edit message';
  static String get replyingTo =>
      isAr ? 'الرد على' : 'Replying to';
  static String get statusLabel => isAr ? 'الحالة' : 'Status';
  static String get statusSent => isAr ? 'تم الإرسال' : 'Sent';
  static String get statusDelivered => isAr ? 'تم التسليم' : 'Delivered';
  static String get statusRead => isAr ? 'تمت القراءة' : 'Read';
  static String get statusPending => isAr ? 'في الانتظار' : 'Pending';
  static String get timeLabel => isAr ? 'الوقت' : 'Time';
  static String get typeLabel => isAr ? 'النوع' : 'Type';
  static String get textLabel => isAr ? 'نص' : 'Text';
  static String selectedCount(int n) =>
      isAr ? '$n محدد' : '$n selected';
  static String get disappearing =>
      isAr ? 'الرسائل ذاتية الاختفاء' : 'Disappearing messages';
  static String get ttlDuration =>
      isAr ? 'مدة بقاء الرسالة:' : 'Message lifetime:';
  static String get ttlOff => isAr ? 'إيقاف' : 'Off';
  static String get ttl1h => isAr ? '1 ساعة' : '1 hour';
  static String get ttl12h => isAr ? '12 ساعة' : '12 hours';
  static String get ttl24h => isAr ? '24 ساعة' : '24 hours';
  static String get ttl7d => isAr ? '7 أيام' : '7 days';
  static String get ttlStartFrom =>
      isAr ? 'بدء احتساب المدة من:' : 'Start the timer from:';
  static String get ttlFromSend =>
      isAr ? 'وقت إرسال الرسالة' : 'When the message is sent';
  static String get ttlFromRead =>
      isAr ? 'وقت قراءة الطرف الآخر لها' : 'When the other party reads it';
  static String get onlineE2e =>
      isAr ? 'متصل الآن' : 'Online';
  static String get e2e =>
      isAr ? 'محادثة آمنة' : 'Secure chat';
  static String get ttlSettings =>
      isAr ? 'إعدادات الرسائل ذاتية الاختفاء' : 'Disappearing messages settings';
  static String get disappearingHint =>
      isAr ? 'الرسائل تختفي تلقائيًا — ' : 'Messages disappear automatically — ';
  static String ttlDays(int n) => isAr ? '$n يوم' : '$n day${n == 1 ? '' : 's'}';
  static String ttlHours(int n) =>
      isAr ? '$n ساعة' : '$n hour${n == 1 ? '' : 's'}';

  // ── Create group ─────────────────────────────────────────────────────────
  static String get groupCreateFailed =>
      isAr ? 'تعذر إنشاء المجموعة' : 'Could not create group';
  static String get groupNameHint =>
      isAr ? 'اسم المجموعة…' : 'Group name…';
  static String get pickMembers =>
      isAr ? 'اختر الأعضاء' : 'Select members';
  static String pickMembersCount(int n) =>
      isAr ? 'اختر الأعضاء ($n)' : 'Select members ($n)';
  static String get noContacts => isAr
      ? 'لا توجد جهات اتصال مقترنة بعد.\nأضف عضوًا بكود أولاً لإنشاء مجموعة.'
      : 'No paired contacts yet.\nAdd a member by code first to create a group.';
  static String get createGroupBtn =>
      isAr ? 'إنشاء المجموعة' : 'Create group';
  static String createGroupBtnCount(int n) =>
      isAr ? 'إنشاء المجموعة ($n)' : 'Create group ($n)';

  // ── Group chat ───────────────────────────────────────────────────────────
  static String membersCountEncrypted(int n) =>
      isAr ? '$n أعضاء' : '$n members';
  static String get firstGroupMessage =>
      isAr ? 'أرسل أول رسالة للمجموعة' : 'Send the group\'s first message';
  static String get groupMembers =>
      isAr ? 'أعضاء المجموعة' : 'Group members';
  static String get leaveGroup =>
      isAr ? 'مغادرة المجموعة' : 'Leave group';
  static String get leaveGroupConfirm =>
      isAr ? 'مغادرة المجموعة؟' : 'Leave group?';
  static String get leaveGroupWarning => isAr
      ? 'سيتم حذف المجموعة ورسائلها من هذا الجهاز.'
      : 'The group and its messages will be deleted from this device.';

  // ── Login / identity ─────────────────────────────────────────────────────
  static String get loginTitle =>
      isAr ? 'WASL - هوية مجهولة' : 'WASL — Anonymous Identity';
  static String get yourIdentity =>
      isAr ? 'هويتك الخاصة' : 'Your identity';
  static String get identityCreated => isAr
      ? 'تم إنشاء عنوانك المحلي بنجاح. لا يتطلب التطبيق أي رقم هاتف أو صلاحيات لجهات الاتصال.'
      : 'Your local address was created. No phone number or contacts permission required.';
  static String get idCopied =>
      isAr ? 'تم نسخ معرّفك' : 'ID copied';
  static String get enterChats =>
      isAr ? 'الدخول إلى المحادثات' : 'Enter chats';

  // ── Name setup ───────────────────────────────────────────────────────────
  static String get nameTooShort =>
      isAr ? 'الاسم قصير — أدخل حرفين على الأقل' : 'Name too short — enter at least 2 characters';
  static String get welcome =>
      isAr ? 'مرحباً بك في وصل' : 'Welcome to WASL';
  static String get nameSetupHint => isAr
      ? 'اختر اسماً معروضاً سيظهر لجهات اتصالك عند إنشاء المحادثات. لا نجمع أرقام هواتف أو بيانات شخصية — يُرسل اسمك فقط ضمن حزمة الاقتران الموقّعة.'
      : 'Choose a display name shown to your contacts when creating chats. We collect no phone numbers or personal data — your name is only sent inside the signed pairing bundle.';
  static String get yourDisplayName =>
      isAr ? 'اسمك المعروض' : 'Your display name';
  static String get nameExample =>
      isAr ? 'مثال: أحمد محمد' : 'e.g. Jane Smith';
  static String get privacyFirst =>
      isAr ? 'خصوصيتك أولويتنا' : 'Your privacy comes first';

  // ── PIN lock ─────────────────────────────────────────────────────────────
  static String get wrongPin =>
      isAr ? 'رمز PIN غير صحيح' : 'Incorrect PIN';
  static String get appLocked =>
      isAr ? 'التطبيق مقفل' : 'App locked';
  static String tooManyAttempts(int seconds) => isAr
      ? 'محاولات كثيرة — حاول بعد $seconds ثانية'
      : 'Too many attempts — try again in $seconds seconds';
  static String get enterPin =>
      isAr ? 'أدخل رمز PIN للمتابعة' : 'Enter PIN to continue';
  static String get unlock => isAr ? 'فتح القفل' : 'Unlock';

  // ── QR scanner ───────────────────────────────────────────────────────────
  static String get yourQr =>
      isAr ? 'معرّفك (QR)' : 'Your ID (QR)';
  static String get qrHint => isAr
      ? 'اسمح للطرف الآخر بمسح الكود أدناه لإنشاء قناة محادثة مباشرة:'
      : 'Let the other party scan the code below to open a direct chat channel:';
  static String get sendingPairRequest =>
      isAr ? 'جارٍ إرسال طلب الاقتران' : 'Sending pairing request';
  static String get waitingAccept =>
      isAr ? 'في انتظار قبول الطرف الآخر...' : 'Waiting for the other party to accept…';
  static String pairRejected(String id) =>
      isAr ? 'تم رفض طلب الاقتران من $id' : 'Pairing request declined by $id';
  static String get manualIdEntry =>
      isAr ? 'إدخال معرّف الجهاز يدوياً' : 'Enter device ID manually';
  static String get scanPairCode =>
      isAr ? 'مسح كود التبادل' : 'Scan pairing code';
  static String get manualEntry =>
      isAr ? 'إدخال يدوي' : 'Manual entry';
  static String get flash => isAr ? 'فلاش' : 'Flash';
  static String get startingCamera =>
      isAr ? 'جارٍ تشغيل الكاميرا...' : 'Starting camera…';
  static String get pointCamera =>
      isAr ? 'وجّه الكاميرا نحو كود الطرف الآخر' : 'Point the camera at the other party\'s code';
  static String get manualNoCamera =>
      isAr ? 'إدخال المعرّف يدوياً بدون كاميرا' : 'Enter ID manually without camera';
  static String get cameraPermission =>
      isAr ? 'إذن الكاميرا مطلوب' : 'Camera permission required';
  static String get grantPermission =>
      isAr ? 'منح الإذن الآن' : 'Grant permission';
  static String get orManual =>
      isAr ? 'أو إدخال المعرّف يدوياً' : 'Or enter the ID manually';

  // ── Settings ─────────────────────────────────────────────────────────────
  static String get relaySettings =>
      isAr ? 'إعدادات خادم الترحيل' : 'Relay server settings';
  static String get serverAddress =>
      isAr ? 'عنوان الخادم / IP' : 'Server address / IP';
  static String get port => isAr ? 'المنفذ' : 'Port';
  static String get useWss =>
      isAr ? 'استخدام WSS الآمن' : 'Use secure WSS';
  static String get saveApply =>
      isAr ? 'حفظ وتطبيق' : 'Save & apply';
  static String get relayUpdated => isAr
      ? 'تم تحديث إعدادات الخادم. جارٍ إعادة الاتصال...'
      : 'Server settings updated. Reconnecting…';
  static String get secureWipe =>
      isAr ? 'المسح الآمن الشامل' : 'Full secure wipe';
  static String get secureWipeWarning => isAr
      ? 'سيؤدي هذا إلى مسح جميع المفاتيح وقواعد بيانات المحادثات والوسائط من هذا الجهاز بشكل لا رجعة فيه.'
      : 'This will irreversibly erase all keys, chat databases, and media from this device.';
  static String get areYouSure =>
      isAr ? 'هل أنت متأكد تماماً؟' : 'Are you absolutely sure?';
  static String get wipingData =>
      isAr ? 'جارٍ مسح البيانات بشكل آمن...' : 'Securely wiping data…';
  static String get wipeEverything =>
      isAr ? 'مسح كل شيء' : 'Wipe everything';
  static String get displayName =>
      isAr ? 'الاسم المعروض' : 'Display name';
  static String get displayNameHint =>
      isAr ? 'الاسم الظاهر للأعضاء المقترنين' : 'Name shown to paired members';
  static String get nameMinChars =>
      isAr ? 'الاسم يجب أن يكون حرفين على الأقل' : 'Name must be at least 2 characters';
  static String get nameSaved =>
      isAr ? 'تم حفظ الاسم' : 'Name saved';
  static String get pinDigits =>
      isAr ? 'رمز PIN (4-6 أرقام)' : 'PIN code (4-6 digits)';
  static String get pinLengthError =>
      isAr ? 'رمز PIN يجب أن يكون 4-6 أرقام' : 'PIN must be 4-6 digits';
  static String get createPin =>
      isAr ? 'إنشاء رمز PIN' : 'Create PIN';
  static String get createPinHint => isAr
      ? 'اختر رمزاً من 4-6 أرقام لقفل التطبيق عند الفتح'
      : 'Choose a 4-6 digit code to lock the app on open';
  static String get confirmPin =>
      isAr ? 'تأكيد رمز PIN' : 'Confirm PIN';
  static String get pinsDontMatch =>
      isAr ? 'الرمزان غير متطابقين' : 'PINs do not match';
  static String get pinEnabled =>
      isAr ? 'تم تفعيل قفل التطبيق' : 'App lock enabled';
  static String get pinEnableFailed =>
      isAr ? 'تعذر تفعيل القفل' : 'Could not enable lock';
  static String get changePin =>
      isAr ? 'تغيير رمز PIN' : 'Change PIN';
  static String get enterCurrentPin =>
      isAr ? 'أدخل رمزك الحالي أولاً' : 'Enter your current PIN first';
  static String get newPin =>
      isAr ? 'رمز PIN جديد' : 'New PIN';
  static String get confirmNewPin =>
      isAr ? 'تأكيد الرمز الجديد' : 'Confirm new PIN';
  static String get pinChanged =>
      isAr ? 'تم تغيير الرمز' : 'PIN changed';
  static String get currentPinWrong =>
      isAr ? 'الرمز الحالي غير صحيح' : 'Current PIN is incorrect';
  static String get disablePinLock =>
      isAr ? 'تعطيل قفل التطبيق' : 'Disable app lock';
  static String get enterCurrentToConfirm =>
      isAr ? 'أدخل رمزك الحالي للتأكيد' : 'Enter your current PIN to confirm';
  static String get pinStillEnabled =>
      isAr ? 'الرمز غير صحيح، القفل لا يزال مفعّلاً' : 'Incorrect PIN — lock is still enabled';
  static String get immediately => isAr ? 'فوراً' : 'Immediately';
  static String afterSeconds(int n) =>
      isAr ? 'بعد $n ثانية' : 'After $n seconds';
  static String get afterOneMinute =>
      isAr ? 'بعد دقيقة واحدة' : 'After 1 minute';
  static String afterMinutes(int n) =>
      isAr ? 'بعد $n دقائق' : 'After $n minutes';
  static String get autoLock =>
      isAr ? 'القفل التلقائي' : 'Auto-lock';
  static String get privacyAndSettings =>
      isAr ? 'الخصوصية والإعدادات' : 'Privacy & settings';
  static String get anonymousIdentity =>
      isAr ? 'الهوية المجهولة' : 'Anonymous identity';
  static String get deviceCryptoId =>
      isAr ? 'معرّف الجهاز' : 'Device ID';
  static String get cryptoIdCopied =>
      isAr ? 'تم نسخ المعرّف' : 'ID copied';
  static String get notSetYet =>
      isAr ? 'لم يُحدد بعد' : 'Not set yet';
  static String get relayServer =>
      isAr ? 'خادم الترحيل' : 'Relay server';
  static String get relayServerAddress =>
      isAr ? 'عنوان خادم الترحيل' : 'Relay server address';
  static String get privacyAndData =>
      isAr ? 'الخصوصية وحماية البيانات' : 'Privacy & data protection';
  static String get readReceipts =>
      isAr ? 'إيصالات القراءة' : 'Read receipts';
  static String get readReceiptsHint =>
      isAr ? 'إرسال واستقبال تأكيدات القراءة' : 'Send and receive read confirmations';
  static String get autoDownloadMedia =>
      isAr ? 'التحميل التلقائي للوسائط' : 'Auto-download media';
  static String get autoDownloadHint =>
      isAr ? 'جلب وتجميع ملفات الوسائط الواردة تلقائياً' : 'Automatically fetch and assemble incoming media';
  static String get encryptionStandards =>
      isAr ? 'معايير الأمان' : 'Security standards';
  static String get pinLock =>
      isAr ? 'قفل التطبيق بـ PIN' : 'PIN app lock';
  static String get pinLockTitle =>
      isAr ? 'قفل التطبيق برمز PIN' : 'Lock app with PIN';
  static String get pinLockOn =>
      isAr ? 'مفعّل — يُطلب PIN عند فتح التطبيق' : 'Enabled — PIN required on app open';
  static String get pinLockOff =>
      isAr ? 'اطلب PIN في كل مرة يُفتح فيها التطبيق' : 'Require PIN every time the app opens';
  static String get appearanceAndLang =>
      isAr ? 'المظهر واللغة' : 'Appearance & language';
  static String get darkMode =>
      isAr ? 'الوضع الليلي' : 'Dark mode';
  static String get appLanguage =>
      isAr ? 'لغة التطبيق' : 'App language';
  static String get arabic => 'العربية';
  static String get clearChatContent =>
      isAr ? 'مسح محتوى الدردشات' : 'Clear chat content';
  static String get clearChatContentHint => isAr
      ? 'حذف كل الرسائل والوسائط مع بقاء جهات الاتصال والمجموعات'
      : 'Delete all messages and media, keep contacts and groups';
  static String get clearChatContentWarning => isAr
      ? 'سيتم حذف جميع الرسائل والوسائط من كل الدردشات نهائياً من هذا الجهاز. ستبقى جهات الاتصال والمجموعات والاقترانات كما هي.'
      : 'All messages and media in every chat will be permanently deleted from this device. Contacts, groups and pairings remain untouched.';
  static String get chatsCleared =>
      isAr ? 'تم مسح محتوى الدردشات' : 'Chat content cleared';
  static String get wipeLocalData =>
      isAr ? 'مسح البيانات المحلية نهائياً' : 'Permanently wipe local data';
  static String get wipeLocalDataHint => isAr
      ? 'تدمير المفاتيح والسجلات المحلية نهائياً'
      : 'Irreversibly destroy keys and local records';
}
