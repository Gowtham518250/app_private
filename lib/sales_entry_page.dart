import 'package:flutter/material.dart';
import 'sharing_intent_service.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:collection';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'secure_token_storage.dart';
import 'scoped_shared_preferences.dart';
import 'app_localizations.dart';
import 'sync_queue_manager.dart';
import 'stock_alert_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'language_provider.dart';
import 'visual_widgets.dart';
import 'dart:typed_data';
import 'package:url_launcher/url_launcher_string.dart';
import 'app_bottom_nav.dart';
import 'payment_announcement_service.dart';
import 'payment_detection_service.dart';
import 'payment_event.dart';
import 'voice_billing_assistant.dart';
import 'roman_indian_voice_normalizer.dart';
import 'bill_generator_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'udhar_reminder_service.dart';
import 'printer_service.dart';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'inventory_management_service.dart';
import 'sale_service.dart';
import 'analytics_engine.dart';
import 'format_helper.dart';
import 'local_storage_service.dart';
import 'scheme_engine.dart';
import 'offline_payment_queue.dart';
import 'package:vibration/vibration.dart';
import 'session_management.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'data_validation_service.dart';
import 'stock_validation_service.dart';



// API Endpoints
const String salesCreateEndpoint = '/api/invoices/sync';
const String salesGetEndpoint = '/api/invoices';

class SalesEntryPage extends StatefulWidget {
  final String? pendingWhatsappText;
  final String? pendingWhatsappOrderId;
  const SalesEntryPage({super.key, this.pendingWhatsappText, this.pendingWhatsappOrderId});

  @override
  State<SalesEntryPage> createState() => _SalesEntryPageState();
}

class _SalesEntryPageState extends State<SalesEntryPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  List<Map<String, TextEditingController>> entries = [];
  bool isLoading = false;
  String message = '';
  double totalAmount = 0.0;
  double totalSubtotal = 0.0;   // pre-tax sum
  double totalCgst = 0.0;       // CGST half of all GST
  double totalSgst = 0.0;       // SGST half of all GST
  bool _withTax = false; // GST Toggle State (Disabled by Default)
  final TextEditingController customerPhoneController = TextEditingController();
  final TextEditingController customerNameController = TextEditingController();
  int? _lastAddedRowIndex = -1;
  bool _isVoiceAssistantOpen = false;
  double _schemeDiscount = 0.0;
  double _flashSaleDiscount = 0.0;
  String _activeSchemeName = '';
  String _paymentAnnounceLang = 'en-IN'; // 🎙️ Payment announcement language
  
  // 🔧 PERFORMANCE OPTIMIZATION: Batch state updates to reduce setState calls
  final List<VoidCallback> _pendingStateUpdates = [];
  bool _isUpdatingState = false;
  
  /// Batch multiple state updates into a single setState
  void _batchStateUpdate(VoidCallback update) {
    _pendingStateUpdates.add(update);
    
    if (!_isUpdatingState) {
      _isUpdatingState = true;
      // Delay slightly to collect more updates
      Future.microtask(() {
        setState(() {
          for (final update in _pendingStateUpdates) {
            update();
          }
          _pendingStateUpdates.clear();
        });
        _isUpdatingState = false;
      });
    }
  }
  
  /// Update multiple state values in a single setState
  void _updateMultipleStateValues({
    String? message,
    bool? isLoading,
    List<Map<String, TextEditingController>>? entries,
    double? totalAmount,
    double? totalSubtotal,
    double? totalCgst,
    double? totalSgst,
    bool? withTax,
    bool? isVoiceAssistantOpen,
    double? schemeDiscount,
    double? flashSaleDiscount,
    String? activeSchemeName,
  }) {
    setState(() {
      if (message != null) this.message = message;
      if (isLoading != null) this.isLoading = isLoading;
      if (entries != null) this.entries = entries;
      if (totalAmount != null) this.totalAmount = totalAmount;
      if (totalSubtotal != null) this.totalSubtotal = totalSubtotal;
      if (totalCgst != null) this.totalCgst = totalCgst;
      if (totalSgst != null) this.totalSgst = totalSgst;
      if (withTax != null) _withTax = withTax;
      if (isVoiceAssistantOpen != null) _isVoiceAssistantOpen = isVoiceAssistantOpen;
      if (schemeDiscount != null) _schemeDiscount = schemeDiscount;
      if (flashSaleDiscount != null) _flashSaleDiscount = flashSaleDiscount;
      if (activeSchemeName != null) _activeSchemeName = activeSchemeName;
    });
  }

  // Haptic Feedback Helpers
  Future<void> _hapticLight() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 50);
    }
    HapticFeedback.lightImpact();
  }

  Future<void> _hapticMedium() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 100);
    }
    HapticFeedback.mediumImpact();
  }

  Future<void> _hapticHeavy() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 200);
    }
    HapticFeedback.heavyImpact();
  }

  Future<void> _hapticSuccess() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [100, 50, 100]);
    }
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 100), () {
      HapticFeedback.lightImpact();
    });
  }

  void _onVoiceOrderParsed(List<Map<String, dynamic>> items) {
    if (items.isEmpty || !mounted) return;

    // Route assistant results through the same duplicate-safe insertion path.
    for (final item in items) {
      final name = (item['name'] ?? item['product_name'] ?? '').toString().trim();
      final qty = ((item['qty'] ?? item['quantity']) as num?)?.toDouble() ?? 1.0;
      final price = (item['price'] as num?)?.toDouble() ?? 0.0;

      if (name.isEmpty || qty <= 0) continue;

      _addVoiceItem(
        name,
        qty,
        providedPrice: price > 0 ? price : null,
        providedGst: double.tryParse(item['gst']?.toString() ?? ''),
        providedBarcode: item['barcode']?.toString(),
      );
    }

    if (mounted) {
      setState(() => _isVoiceAssistantOpen = false);
      calculateTotal();
    }
  }

  Future<void> _shareOnWhatsApp() async {
    if (totalAmount == 0) return;
    
    final customerPhone = customerPhoneController.text.trim();
    if (customerPhone.isEmpty) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter customer phone number first')));
       return;
    }

    final billText = "Hello ${customerNameController.text.trim()},\n\nYour bill from ${_shopNameForDynamicQr} is ₹${totalAmount.toStringAsFixed(2)}.\n\nItems:\n" +
      entries.where((e) => e['item']?.text.isNotEmpty ?? false).map((e) => "- ${e['item']?.text ?? ''}: ${e['qty']?.text ?? '1'} x ${e['price']?.text ?? '0'}").join("\n") +
      "\n\nTotal: ₹${totalAmount.toStringAsFixed(2)}\n\nThank you for shopping!";

    final url = "https://wa.me/91$customerPhone?text=${Uri.encodeComponent(billText)}";
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp. Is it installed?')),
      );
    }
  }

  void _openVoiceBillingMenu() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Voice billing',
                style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w800, color: const Color(0xFF111827)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.smart_display_rounded, color: Color(0xFF4F46E5)),
              title: Text('Guided line items', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              subtitle: Text('Step-by-step — one product at a time', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600])),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _isVoiceAssistantOpen = true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF10B981)),
              title: Text('Speak full bill', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              subtitle: Text('Multiple items in one go (uses mic overlay)', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600])),
              onTap: () {
                Navigator.pop(ctx);
                _startListening();
              },
            ),
            if (_isVoiceAssistantOpen)
              ListTile(
                leading: Icon(Icons.close_rounded, color: Colors.grey[700]),
                title: Text('Close guided panel', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _isVoiceAssistantOpen = false);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

 // For highlighting the recently scanned item
  bool _paymentSoundEnabled = true;
  String _paymentSoundLang = 'en-US';
  String _speechInputLang = 'en-US';
  AnnouncementMode _announcementMode = AnnouncementMode.shopkeeper;
  StreamSubscription<PaymentEvent>? _paymentSubscription;
  final List<PaymentEvent> _recentHistory = []; // HISTORY TRACKER
  final LinkedHashSet<String> _processedPaymentIds = LinkedHashSet<String>(); // FIX-1: bounded set with FIFO
  // FIX-UPI-LOOP: Session ID tied to the current bill — changes on every new bill so
  // stale LIKELY re-announce events from the singleton stream are discarded.
  String _billSessionId = '';
  DateTime? _lastScanTime; // 🛑 BARCODE DEBOUNCE
  double _scanFlashOpacity = 0.0; // ✨ Barcode scan visual feedback

  // Animation controllers
  late AnimationController _totalPulseController;
  late Animation<double> _totalPulse;
  late AnimationController _entranceController;
  late Animation<double> _entranceFade;
  late Animation<Offset> _entranceSlide;
  // Voice pulse animation controllers
  late List<AnimationController> _voicePulseControllers;

  // Voice Assistant State
  final stt.SpeechToText _speechToText = stt.SpeechToText();
  bool _isListening = false;
  String _lastWords = '';
  double _voiceConfidence = 1.0;
  bool _speechEnabled = false;

  // â”€â”€ ADVANCED FUZZY MATCHING (Dice's Coefficient) for Noise Resistance â”€â”€
  double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    
    // Check if one string contains the other (strong indicator)
    if (s1.contains(s2) || s2.contains(s1)) {
      return 0.85;
    }
    
    // Calculate Levenshtein distance (edit distance)
    final levenshteinScore = _levenshteinDistance(s1, s2);
    final maxLen = s1.length > s2.length ? s1.length : s2.length;
    final levScore = 1.0 - (levenshteinScore / maxLen);
    
    // Calculate bigram similarity
    Set<String> getBigrams(String str) {
      final bigrams = <String>{};
      for (int i = 0; i < str.length - 1; i++) {
        bigrams.add(str.substring(i, i + 2));
      }
      return bigrams;
    }
    final b1 = getBigrams(s1);
    final b2 = getBigrams(s2);
    final intersection = b1.intersection(b2).length;
    final bigramScore = b1.length + b2.length == 0 ? 0.0 : (2.0 * intersection) / (b1.length + b2.length);
    
    // Weighted average: 60% Levenshtein, 40% Bigram
    return (levScore * 0.6) + (bigramScore * 0.4);
  }

  int _levenshteinDistance(String s1, String s2) {
    List<int> costs = [];
    for (int i = 0; i <= s1.length; i++) {
      int lastValue = i;
      for (int j = 0; j <= s2.length; j++) {
        if (i == 0) {
          costs.add(j);
        } else if (j > 0) {
          int newValue = costs[j - 1];
          if (s1.codeUnitAt(i - 1) != s2.codeUnitAt(j - 1)) {
            newValue = 1 + [costs[j], lastValue, costs[j - 1]].reduce((a, b) => a < b ? a : b);
          }
          costs[j - 1] = lastValue;
          lastValue = newValue;
        }
      }
      if (i > 0) {
        costs.add(lastValue);
      }
    }
    return costs.isEmpty ? 0 : costs.last;
  }

  // â”€â”€ VOICE CLEANING: Remove unwanted noise/filler â”€â”€
  String _cleanVoiceText(String input) {
    if (input.isEmpty) return '';
    
    // 1. Convert to lowercase for matching
    String text = input.toLowerCase();
    
    // 2. Remove common filler words & noise (Expanded for Indian Context)
    final List<String> noise = [
      'uhm', 'uh', 'ah', 'like', 'i mean', 'you know', 'basically', 'actually', 
      'please add', 'add', 'item', 'product', 'ok', 'alright', 'stop', 'the', 'a',
      'and', 'next', 'then', 'sir', 'ek', 'do', 'aur', 'kardo', 'bhaiya', 'bhai',
      'karo', 'kar', 'de', 'do', 'le lo', 'daal do', 'sugar', 'patti'
    ];
    
    for (var word in noise) {
      text = text.replaceAll(RegExp('\\b$word\\b'), '');
    }
    
    // 3. Trim extra whitespace
    text = text.replaceAll(RegExp('\\s+'), ' ').trim();
    
    // 4. Proper Case (Capitalize first letter of each word)
    if (text.isEmpty) return '';
    return text.split(' ').map((str) {
      if (str.isEmpty) return str;
      return str[0].toUpperCase() + str.substring(1);
    }).join(' ');
  }

    Future<void> _startListeningForItem(TextEditingController controller) async {
      final hasPermission = await _speechToText.initialize();
      if (hasPermission) {
        setState(() => _isListening = true);
        _speechToText.listen(
          onResult: (result) {
            // "Apply Product Alone" optimization: Clean noise and map to controller
            if (result.finalResult) {
              final cleaned = _cleanVoiceText(result.recognizedWords);
              if (cleaned.isNotEmpty) {
                controller.text = cleaned;
              }
              _isListening = false;
              calculateTotal();
            }
          },
          listenFor: const Duration(seconds: 15),
          pauseFor: const Duration(seconds: 3),
          localeId: _speechInputLang,
        );
      }
    }

  void _showLanguageMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20, 
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.language_rounded, color: Colors.indigo),
                const SizedBox(width: 10),
                Text('Language & Keyboard', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            Text('1. Voice Input (Mic) Language:', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                {'code': 'en-IN', 'name': 'English'},
                {'code': 'hi-IN', 'name': 'Hindi / à¤¹à¤¿à¤¨à¥à¤¦à¥€'},
                {'code': 'te-IN', 'name': 'Telugu / à°¤à±†à°²à±à°—à±'},
                {'code': 'ta-IN', 'name': 'Tamil / à®¤à®®à®¿à®´à¯'},
                {'code': 'mr-IN', 'name': 'Marathi / à¤®à¤°à¤¾à¤ à¥€'},
              ].map((l) => ActionChip(
                label: Text(l['name']?.toString() ?? '', style: GoogleFonts.poppins(fontSize: 12, color: _speechInputLang == l['code'] ? Colors.white : Colors.black87)),
                backgroundColor: _speechInputLang == l['code'] ? Colors.indigo : Colors.grey[200],
                side: _speechInputLang == l['code'] ? const BorderSide(color: Colors.indigo) : BorderSide.none,
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  final code = l['code']?.toString() ?? 'en-IN';
                  await prefs.setString('speech_input_lang', code);
                  setState(() => _speechInputLang = code);
                  if (ctx.mounted && Navigator.canPop(ctx)) {
                    Navigator.pop(ctx);
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Voice input set to ${l['name']?.toString() ?? ''}')));
                  }
                },
              )).toList(),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16.0),
              child: Divider(),
            ),
            Text('2. How to Type in Your Language?', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.blue.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.blue.withOpacity(0.2))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.keyboard_alt_outlined, color: Colors.blue, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('To type in your local language (Hindi, Telugu, etc.), open your device keyboard, tap the 🌐 (Globe) icon or press and hold the Spacebar to add your language layout.', 
                      style: GoogleFonts.poppins(fontSize: 13, color: Colors.black87, height: 1.4)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // â”€â”€ Payment mode â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  bool _isOnlinePayment = false;       // false = cash/offline, true = online/UPI
  bool _paymentConfirmed = false;      // only allow bill after this
  // Optimistic default (true) so the button doesn't flash on screen before
  // the first permission check resolves; _checkPaymentPermissions() in
  // initState corrects this within ~2s, and it's kept in sync afterwards by
  // _recheckNotificationPermission() (called on app resume and right after
  // the user returns from the notification-access settings screen).
  bool _hasNotifPermission = true;
  double _paidAmount = 0.0;            // Actual amount received via UPI/Cash
  Uint8List? _paymentQrBytes;          // QR image from SharedPreferences
  String? _upiId;                      // Textual UPI ID for dynamic QR
  String? _shopNameForDynamicQr;       // Name for the VPA tag
  DateTime? _selectedDueDate;          // Deadline for unpaid amount
  final TextEditingController _dueDateController = TextEditingController();
  bool _isVoiceProcessing = false; // Flag to prevent UI listeners from adding duplicate items during voice entry
  bool _borrowWaitingForCustomer = false;


  // Local product catalog keyed by barcode
  Map<String, Map<String, dynamic>> _localProducts = {};

  // Printer State
  final BlueThermalPrinter bluetooth = BlueThermalPrinter.instance;
  List<BluetoothDevice> _devices = [];
  BluetoothDevice? _selectedDevice;
  bool _connected = false;
  
  // Offline Queue for failed API writes
  final OfflinePaymentQueue _offlineQueue = OfflinePaymentQueue();

  Future<void> _printBluetooth() async {
    final itemsList = entries
        .where((e) => e['item']?.text.isNotEmpty ?? false)
        .map((e) => {
              'product_name': e['item']?.text ?? '',
              'qty': e['qty']?.text.isEmpty ?? true ? '1' : e['qty']?.text ?? '1',
              'price': e['price']?.text.isEmpty ?? true ? '0' : e['price']?.text ?? '0',
            })
        .toList();

    await PrinterService.printBill(
      context: context,
      invoiceId: 'INV-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      customerName: customerNameController.text.isNotEmpty ? customerNameController.text : "Cash Customer",
      items: itemsList,
      totalAmount: totalAmount,
      gstPercent: 18.0,
    );
  }

  // â”€â”€ Official Local & Global Dataset (GS1 / Regulatory Standard) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  final Map<String, Map<String, dynamic>> _globalProductDataset = {
    '8901030000001': {'name': 'Dove Soap 100g', 'price': '68', 'gst': '18'},
    '8901719114172': {'name': 'Lays Blue India Magic 50g', 'price': '20', 'gst': '12'},
    '8906002961019': {'name': 'Maggi Noodles 70g', 'price': '15', 'gst': '5'},
    '8901058849764': {'name': 'Pepsi 500ml', 'price': '42', 'gst': '12'},
    '8901491101831': {'name': 'Dettol Handwash 200ml', 'price': '105', 'gst': '18'},
    '8901207040084': {'name': 'Parle-G Biscuit 80g', 'price': '5', 'gst': '5'},
    '8901491501013': {'name': 'Maaza Mango Drink 600ml', 'price': '45', 'gst': '12'},
    '8901058000014': {'name': 'Horlicks 500g Jar', 'price': '255', 'gst': '18'},
    '8901063014112': {'name': 'Good Day Biscuit 100g', 'price': '20', 'gst': '5'},
    '8901088123456': {'name': 'Tata Tea Premium 250g', 'price': '135', 'gst': '5'},
    '8901088001159': {'name': 'Tata Salt 1kg', 'price': '28', 'gst': '5'},
    '8901262010014': {'name': 'Amul Butter 500g', 'price': '280', 'gst': '12'},
    '8901138511786': {'name': 'Colgate Strong Teeth 200g', 'price': '128', 'gst': '18'},
    '8901030353459': {'name': 'Lifebuoy Total 125g', 'price': '40', 'gst': '18'},
    '8901138834137': {'name': 'Pepsodent GermiCheck 150g', 'price': '115', 'gst': '18'},
    '8906002960104': {'name': 'Maggi Masala-Ae-Magic 6g', 'price': '5', 'gst': '5'},
    '8901063141153': {'name': 'Britannia Marie Gold 250g', 'price': '35', 'gst': '5'},
    '8901030869615': {'name': 'Ponds Powder 100g', 'price': '110', 'gst': '18'},
    '8901491361006': {'name': 'Vim Bar 200g', 'price': '18', 'gst': '18'},
    '8901058141311': {'name': 'Kissan Ketchup 1kg', 'price': '165', 'gst': '12'},
    '8901058004128': {'name': 'Red Label Tea 500g', 'price': '290', 'gst': '5'},
    '8901262020204': {'name': 'Amul Milk 500ml', 'price': '28', 'gst': '0'},
    '8901030138246': {'name': 'Lux Soap 100g', 'price': '45', 'gst': '18'},
    '8901030691230': {'name': 'Surf Excel Quick Wash 1kg', 'price': '210', 'gst': '18'},
    '8908000676008': {'name': 'Catch Salt-N-Pepper', 'price': '35', 'gst': '5'},
    '8901719114189': {'name': 'Kurkure Masala Munch 80g', 'price': '30', 'gst': '12'},
    '8901058000106': {'name': 'Bournvita Refill 500g', 'price': '240', 'gst': '18'},
    '8901138511779': {'name': 'Colgate MaxFresh 150g', 'price': '98', 'gst': '18'},
    '8901030563452': {'name': 'Bru Instant Coffee 100g', 'price': '185', 'gst': '12'},
  };

  String _currentCountry = 'Unknown';

  Future<void> _initSpeech() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _paymentSoundLang = prefs.getString('payment_sound_lang') ?? 'en-US';
      
      _speechEnabled = await _speechToText.initialize(
        onError: (val) {
          if (kDebugMode) debugPrint('Error: $val');
        },
        onStatus: (val) {
          if (kDebugMode) debugPrint('Status: $val');
        },
      );
      setState(() {});
    } catch (e) {
      if (kDebugMode) debugPrint('Speech init error: $e');
    }
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() => _isListening = false);
  }

  void _startListening() async {
    bool available = await _speechToText.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          setState(() => _isListening = false);
        }
      },
      onError: (error) {
        setState(() => _isListening = false);
        if (kDebugMode) debugPrint('Voice Error: $error');
      },
    );

    if (available) {
      // Clear previous voice text when starting a new listening session
      setState(() {
        _lastWords = '';
        _voiceConfidence = 1.0;
        _isListening = true;
      });
      _speechToText.listen(
        onResult: _onSpeechResult,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        cancelOnError: true,
        partialResults: true,
        localeId: _speechInputLang,
      );
    } else {
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('⚠️ Voice Recognition Unavailable')),
       );
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (mounted) {
      setState(() {
        _lastWords = result.recognizedWords;
        _voiceConfidence = result.confidence;
      });
    }
    
    if (result.finalResult) {
      if (result.confidence > 0.5) {
        _splitAndParseMultipleItems(result.recognizedWords);
      } else {
        // Low confidence, let user retry!
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Low confidence, please try again!'),
              backgroundColor: Colors.orange.shade600,
            ),
          );
        }
      }
      _stopListening();
    }
  }

  /// 🚀 100-CRORE FEATURE: Multi-Item Voice Parser
  /// Handles: "2 kg sugar 60, 1 oil 150 aur 3 soap" → 3 bill rows in one breath
  void _splitAndParseMultipleItems(String fullText) async {
    if (fullText.trim().isEmpty) return;

    // Split on conjunctions, commas, and Indic danda
    final splitPattern = RegExp(
      r'(?:\s*(?:,|;|ØŒ|ï¼Œ|\||\u0964)\s*)|\s+(?:and|aur|phir|then|also|plus|à¤¤à¤¥à¤¾|à¤”à¤°)\s+',
      caseSensitive: false,
    );

    final rawParts = fullText
        .split(splitPattern)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final segments = <String>[];
    for (final s in rawParts) {
      if (segments.isEmpty || segments.last.toLowerCase() != s.toLowerCase()) {
        segments.add(s);
      }
    }

    if (segments.length <= 1) {
      // Single item — use original logic
      _processVoiceCommand(fullText);
      return;
    }

    // Show a beautiful multi-item confirmation dialog
    if (!mounted) return;

    // Parse each segment to show preview
    final List<String> preview = segments
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value.trim()}')
        .toList();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.mic_rounded, color: Color(0xFF6366F1), size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '🎙️ AI Detected ${segments.length} Items',
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('I heard:', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            ...preview.map((item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: Color(0xFF10B981), size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w500))),
                ],
              ),
            )),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '✍️¨ All items will be auto-added to the bill!',
                style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFF4338CA)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('RETRY', style: GoogleFonts.poppins(color: Colors.red)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
            label: Text('ADD ALL ${segments.length} ITEMS', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Process each segment with a small delay for UX
      for (int i = 0; i < segments.length; i++) {
        await Future.delayed(Duration(milliseconds: i * 150));
        _processVoiceCommand(segments[i]);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Text('✅ ${segments.length} items added by Voice AI!', 
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              ],
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  bool _handleSpecialVoiceCommands(String command) {
    // Check for payment commands
    final paymentCommands = {
      r'\b(cash|naqad|nakad)\b': 'cash',
      r'\b(upi|online|phonepe|gpay|paytm|google pay|net banking)\b': 'online',
      r'\b(card|credit card|debit card|swipe)\b': 'card',
    };

    for (var entry in paymentCommands.entries) {
      if (RegExp(entry.key, caseSensitive: false).hasMatch(command)) {
        // Set payment mode
        setState(() {
          _isOnlinePayment = entry.value != 'cash';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎯 Payment mode set to ${entry.value}!'),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return true;
      }
    }

    // Check for borrow/credit commands
    final borrowCommands = RegExp(
      r'\b(borrow|credit|udhar|haq|dena bad mein|baad mein)\b',
      caseSensitive: false,
    );
    if (borrowCommands.hasMatch(command)) {
      // Show borrow dialog
      WidgetsBinding.instance.addPostFrameCallback((_) {
        borrowSale();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎯 Borrow mode activated!'),
          backgroundColor: const Color(0xFF4338CA),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return true;
    }

    // Check for generate bill command
    final billCommands = RegExp(
      r'\b(generate bill|create bill|save sale|finish sale|done|complete)\b',
      caseSensitive: false,
    );
    if (billCommands.hasMatch(command)) {
      // Generate bill
      WidgetsBinding.instance.addPostFrameCallback((_) {
        generateBill();
      });
      return true;
    }

    return false;
  }

  Future<void> _processVoiceCommand(String text) async {
    String command = text.toLowerCase().trim();
    if (command.isEmpty) return;

    // Normalize Romanized Indian speech, regional number words, and unit variants
    // before the existing sales parser interprets quantity/price/product.
    command = RomanIndianVoiceNormalizer.normalize(command, locale: _speechInputLang);

    // Check for special voice commands first
    if (_handleSpecialVoiceCommands(command)) {
      return;
    }

    if (kDebugMode) debugPrint('📡 Order-Independent Parser: $command (Confidence: $_voiceConfidence)');

    double qty = 1.0;
    double price = 0.0;
    String itemName = '';
    String unitFound = '';

    // â”€â”€ 1. NUMERICAL MAPPING (Multi-lingual support) â”€â”€
    final Map<String, double> numberMap = {
      'half': 0.5, 'pau': 0.25, 'aadha': 0.5, 'pauna': 0.75,
      'ek': 1, 'do': 2, 'theen': 3, 'char': 4, 'panch': 5, 'che': 6, 'saat': 7, 'aath': 8, 'nau': 9, 'das': 10,
      'gyara': 11, 'bara': 12, 'bees': 20, 'pachis': 25, 'pachas': 50, 'sau': 100, 'hazar': 1000
    };

    // â”€â”€ 2. UNIT EXTRACTION (Find number closest to the unit) â”€â”€
    final RegExp unitRegex = RegExp(r'\b(kg|kilogram|kilo|g|gram|ltr|liter|litre|ml|milliliter|pk|pkt|packet|packets|units|pieces|pcs|dozen|dz)\b', caseSensitive: false);
    final List<RegExpMatch> unitMatches = unitRegex.allMatches(command).toList();
    
    if (unitMatches.isNotEmpty) {
      final unitMatch = unitMatches.first;
      unitFound = unitMatch.group(1) ?? '';
      
      // Look for number BEFORE or AFTER the unit (e.g., "1kg" or "kilo 1")
      final RegExp nearNumRegex = RegExp(r'(\d+(?:\.\d+)?)');
      int start = (unitMatch.start - 8).clamp(0, command.length);
      int end = (unitMatch.end + 8).clamp(0, command.length);
      String textNearUnit = command.substring(start, end);
      
      final numInContext = nearNumRegex.firstMatch(textNearUnit);
      if (numInContext != null) {
        final numStr = numInContext.group(1) ?? '';
        qty = double.tryParse(numStr) ?? 1.0;
        command = command.replaceFirst(numStr, ' ');
        command = command.replaceFirst(unitFound, ' ');
      }
    }

    // â”€â”€ 3. PRICE EXTRACTION (Find remaining standalone numbers) â”€â”€
    // First strip currency words so they don't pollute item name
    // e.g. "tomato 100 rupees" → strip "rupees" → price=100, item=tomato
    final RegExp currencyWords = RegExp(
      r'\b(rupees?|rupaiye?|rupaya?|rs\.?|inr|paise?|bucks?|à¤°à¥à¤ªà¤¯à¥‡|à¤°à¥à¤ªà¤¯à¤¾)\b',
      caseSensitive: false,
    );
    command = command.replaceAll(currencyWords, ' ');

    final RegExp priceRegex = RegExp(r'\b(\d+(?:\.\d+)?)\b');
    final List<RegExpMatch> pMatches = priceRegex.allMatches(command).toList();
    if (pMatches.isNotEmpty) {
       // Take the largest/last number as price
       final priceStr = pMatches.last.group(1) ?? '';
       price = double.tryParse(priceStr) ?? 0.0;
       command = command.replaceFirst(priceStr, ' ');
    }

    // â”€â”€ 4. MULTI-LINGUAL NUMERIC FALLBACK (ek, do, etc) â”€â”€
    for (var entry in numberMap.entries) {
      if (command.contains(entry.key)) {
        if (qty == 1.0) qty = entry.value;
        command = command.replaceFirst(entry.key, ' ');
      }
    }

    // â”€â”€ 5. ITEM NAME EXTRACTION (Remaining Text) â”€â”€
    // Strip filler / stop words
    final stopWords = [
      'add', 'extra', 'plus', 'please', 'give', 'me', 'i', 'want',
      'aur', 'karo', 'chahiye', 'daalo', 'ka', 'ko', 'hi', 'ke',
      'wala', 'wali', 'dena', 'lena', 'dedo', 'lagao',
      'worth', 'ka', 'ki', 'price', 'cost', 'rate',
    ];
    for (var word in stopWords) {
      command = command.replaceAll(RegExp(r'\b' + word + r'\b', caseSensitive: false), ' ');
    }
    
    itemName = command.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (itemName.isEmpty) return;

    if (kDebugMode) debugPrint('🎯 Parsed: Item="$itemName", Qty=$qty $unitFound, Price=₹$price');

    // â”€â”€ 🎯 6. FUZZY MATCH & SUBMIT 🎯 â”€â”€
    Map<String, dynamic>? bestMatch;
    double bestScore = 0.0;
    
    
    final List<Map<String, dynamic>> localProducts = await LocalStorageService.loadBackendProducts();
    final Map<String, dynamic> localDict = await LocalStorageService.loadLocalProducts();
    
    final List<Map<String, dynamic>> allCatalog = [
      ...localProducts,
      ...localDict.values.map((e) => Map<String, dynamic>.from(e))
    ];

    for (var product in allCatalog) {
      final pName = product['product_name']?.toString().toLowerCase() ?? '';
      final score = _calculateSimilarity(itemName.toLowerCase(), pName);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = product;
      }
    }

    final finalPrice = (price > 0) ? price : double.tryParse(bestMatch?['price']?.toString() ?? '0') ?? 0.0;
    final finalGst = double.tryParse(bestMatch?['gst_percent']?.toString() ?? '18') ?? 18.0;

    if (bestMatch != null && bestScore > 0.75) { 
      // HIGH CONFIDENCE: Add immediately
      _addVoiceItem(
        bestMatch['product_name']?.toString() ?? itemName,
        qty,
        providedPrice: finalPrice,
        providedGst: finalGst,
        providedBarcode: bestMatch['barcode']?.toString() ?? bestMatch['id']?.toString() ?? ''
      );
    } else if (bestMatch != null && bestScore > 0.35) {
      // MEDIUM CONFIDENCE: Ask user
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.psychology_outlined, color: Color(0xFF6366F1)),
              const SizedBox(width: 10),
              const Text('AI Suggestion'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('I heard "$text"', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              Text('Did you mean:', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(12),
                width: double.infinity,
                decoration: BoxDecoration(color: const Color(0xFF6366F1).withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bestMatch?['product_name'] ?? itemName, style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: const Color(0xFF4338CA))),
                    Text('Qty: $qty $unitFound | Price: ₹$finalPrice', style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFF6366F1))),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('NO, TRY AGAIN')),
            ElevatedButton(
              onPressed: () {
                _addVoiceItem(
                  bestMatch?['product_name'] ?? itemName,
                  qty,
                  providedPrice: finalPrice,
                  providedGst: finalGst,
                  providedBarcode: bestMatch?['barcode']?.toString() ?? bestMatch?['id']?.toString() ?? ''
                );
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
              child: const Text('YES, ADD'),
            ),
          ],
        ),
      );
    } else {
      // LOW CONFIDENCE: Manual add
       _addVoiceItem(itemName, qty, providedPrice: finalPrice);
    }
  }

  void _addVoiceItem(String name, double qty, {double? providedPrice, double? providedGst, String? providedBarcode}) {
    if (!mounted || name.trim().isEmpty || qty <= 0) return;

    setState(() {
      _isVoiceProcessing = true;

      final normalizedName = name.trim().toLowerCase();
      final incomingPrice = providedPrice ?? 0.0;
      final incomingBarcode = (providedBarcode ?? '').trim();

      // Same product + same price = one bill line. Merge quantity instead
      // of creating a second identical row.
      int existingIdx = -1;
      for (int i = 0; i < entries.length; i++) {
        final rowName = entries[i]['item']?.text.trim().toLowerCase() ?? '';
        if (rowName.isEmpty || rowName != normalizedName) continue;

        final rowPrice =
            double.tryParse(entries[i]['price']?.text.trim() ?? '') ?? 0.0;
        final rowBarcode = entries[i]['barcode']?.text.trim() ?? '';

        final sameBarcode = incomingBarcode.isNotEmpty &&
            rowBarcode.isNotEmpty &&
            incomingBarcode == rowBarcode;
        final samePrice = incomingPrice <= 0 ||
            rowPrice <= 0 ||
            (rowPrice - incomingPrice).abs() < 0.01;

        if (sameBarcode || samePrice) {
          existingIdx = i;
          break;
        }
      }

      if (existingIdx >= 0) {
        final currentQty =
            double.tryParse(entries[existingIdx]['qty']?.text.trim() ?? '') ??
                0.0;
        final mergedQty = currentQty + qty;
        entries[existingIdx]['qty']?.text =
            mergedQty % 1 == 0 ? mergedQty.toInt().toString() : mergedQty.toString();

        if ((entries[existingIdx]['price']?.text.trim().isEmpty ?? true) &&
            incomingPrice > 0) {
          entries[existingIdx]['price']?.text = incomingPrice.toStringAsFixed(0);
        }
        if (providedGst != null && entries[existingIdx]['gst'] != null) {
          entries[existingIdx]['gst']!.text = providedGst.toStringAsFixed(0);
        }
        if (incomingBarcode.isNotEmpty && entries[existingIdx]['barcode'] != null) {
          entries[existingIdx]['barcode']!.text = incomingBarcode;
        }
      } else {
        int targetIdx = -1;
        for (int i = 0; i < entries.length; i++) {
          if ((entries[i]['item']?.text.isEmpty ?? true) &&
              (entries[i]['price']?.text.isEmpty ?? true)) {
            targetIdx = i;
            break;
          }
        }

        if (targetIdx == -1) {
          addEntry();
          targetIdx = entries.length - 1;
        }

        entries[targetIdx]['item']?.text = name.trim();
        entries[targetIdx]['qty']?.text =
            qty % 1 == 0 ? qty.toInt().toString() : qty.toString();

        entries[targetIdx]['price']?.text =
            incomingPrice > 0 ? incomingPrice.toStringAsFixed(0) : '';

        if (providedGst != null && entries[targetIdx]['gst'] != null) {
          entries[targetIdx]['gst']!.text = providedGst.toStringAsFixed(0);
        }
        if (incomingBarcode.isNotEmpty && entries[targetIdx]['barcode'] != null) {
          entries[targetIdx]['barcode']!.text = incomingBarcode;
        }
      }

      calculateTotal();
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _isVoiceProcessing = false);
    });

    // 🚀 100/100 REAL-TIME STOCK PULSE: Alert if merchant adds an item that is low in stock
    InventoryManagementService.checkStockRealtime(name).then((data) {
      if (data != null && (data['isLow'] == true || (data['stock'] as num) <= 2) && mounted) {
         final stockQty = (data['stock'] as num).toInt();
         final pName = data['productName'];
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(
             backgroundColor: Colors.orange[800],
             content: Row(
               children: [
                 const Icon(Icons.warning_amber_rounded, color: Colors.white),
                 const SizedBox(width: 8),
                 Expanded(child: Text('⚠️ LOW STOCK: $pName (Only $stockQty left)', 
                   style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13))),
               ],
             ),
             duration: const Duration(seconds: 4),
             behavior: SnackBarBehavior.floating,
             shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
           )
         );
      }
    });
  }

  void _showQuickAddCustomer() {
    final nameC = TextEditingController();
    final phoneC = TextEditingController(text: customerPhoneController.text);
    final addressC = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('New Customer', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: const Color(0xFF4F46E5))),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                decoration: InputDecoration(
                  labelText: 'Name *',
                  prefixIcon: const Icon(Icons.person, color: Color(0xFF4F46E5)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneC,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Phone *',
                  prefixIcon: const Icon(Icons.phone, color: Color(0xFF4F46E5)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: addressC,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Address',
                  prefixIcon: const Icon(Icons.location_on, color: Color(0xFF4F46E5)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F46E5), foregroundColor: Colors.white),
            onPressed: () async {
              final rawPhone = phoneC.text.trim();
              final digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
              final normalizedPhone =
                  digits.startsWith('91') && digits.length == 12
                      ? digits.substring(2)
                      : digits;

              if (normalizedPhone.length != 10 ||
                  !RegExp(r'^[6-9][0-9]{9}$').hasMatch(normalizedPhone)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('⚠️ Enter a valid 10-digit Indian mobile number'),
                    backgroundColor: Color(0xFFEF4444),
                  ),
                );
                return;
              }

              final List<dynamic> customers = await LocalStorageService.loadLocalCustomers();
              
              // If name is empty, use 'Customer'
              final finalName = nameC.text.trim().isEmpty ? 'Customer' : nameC.text.trim();
              customers.add({
                'name': finalName,
                'phone': normalizedPhone,
                'address': addressC.text.trim(),
                'joining_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
              });
              await LocalStorageService.saveLocalCustomers(customers);
              
              // 🔵 SYNC TO BACKEND (with offline fallback and retry queue)
              try {
                await _saveCustomerToBackend(
                  nameC.text.trim(),
                  phoneC.text.trim(),
                  addressC.text.trim(),
                );
              } catch (e) {
                // Queue for retry if backend sync fails
                await _queueOfflineAction('save_customer', {
                  'name': nameC.text.trim(),
                  'phone': normalizedPhone,
                  'address': addressC.text.trim(),
                });
                if (kDebugMode) debugPrint('⚠️ Customer backend sync failed, queued for retry');
              }
              
              if (!mounted) return;
              final wasBorrowRequest = _borrowWaitingForCustomer;
              setState(() {
                customerPhoneController.text = normalizedPhone;
                _loadLocalCustomers(); // Refresh dropdown
                _borrowWaitingForCustomer = false;
              });
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    wasBorrowRequest
                        ? '✅ Customer added. Borrow NOT recorded yet — tap “Record Borrow” to continue.'
                        : '✅ Customer added!',
                  ),
                  backgroundColor: const Color(0xFF10B981),
                  duration: const Duration(seconds: 4),
                ),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  // â”€â”€ Barcode / QR scan â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _scanProductCode() async {
    final result = await Navigator.pushNamed(context, '/qr-scanner');
    if (result == null) return;
    
    if (result is String) {
      final code = result.trim();
      if (code.isNotEmpty) {
        await _handleScannedBarcode(code);
      }
    } else if (result is List<String>) {
      for (final code in result) {
        final c = code.trim();
        if (c.isNotEmpty) {
          await _handleScannedBarcode(c);
        }
      }
    }
  }

  SnackBar _styledSnackBar(String msg, {bool isError = false}) => SnackBar(
        content: Text(msg,
            style: GoogleFonts.poppins(fontSize: 13, color: Colors.black)),
        backgroundColor:
            isError ? const Color(0xFFEF4444) : const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      );

  List<Map<String, dynamic>> _knownProducts = [];
  List<Map<String, dynamic>> _knownCustomers = [];

  Future<void> _loadLocalProducts() async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> known = [];

    // Load backend products first
    try {
      final backendProds = await LocalStorageService.loadBackendProducts();
      for (var p in backendProds) {
        final pBarcode = p['barcode'] ?? '';
        final pData = {
          'id': p['id']?.toString() ?? '',
          'name': p['product_name'] ?? p['name'] ?? '',
          'price': p['price']?.toString() ?? '0',
          'gst': p['gst_percent']?.toString() ?? '18',
          'barcode': pBarcode,
        };
        known.add(pData);
        // Also put them in localProducts for quick lookup during barcode scan!
        if (pBarcode.toString().isNotEmpty) {
           _localProducts[pBarcode.toString()] = pData;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading backend products: $e');
    }

    // Load local products
    try {
      final localMap = await LocalStorageService.loadLocalProducts();
      setState(() {
        _localProducts = localMap.map((key, value) => MapEntry(key.toString(), Map<String, dynamic>.from(value)));
      });
      known.addAll(_localProducts.values.map((v) => Map<String, dynamic>.from(v)));
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading local products: $e');
    }

    // â”€â”€ Also seed known products from history for autocomplete â”€â”€
    try {
      final List<dynamic> history = await LocalStorageService.loadSales();
      final Set<String> seenNames = known.map((e) => e['name'].toString().toLowerCase().trim()).toSet();
      
      for (var sale in history) {
        final List<dynamic> items = sale['items'] ?? [];
        for (var item in items) {
          String rawName = item['item']?.toString() ?? '';
          if (rawName.isEmpty) continue;
          
          if (rawName.contains('_')) {
             rawName = rawName.substring(0, rawName.lastIndexOf('_'));
          }
          final nameLower = rawName.toLowerCase().trim();
          
          if (!seenNames.contains(nameLower)) {
            seenNames.add(nameLower);
            known.add({
              'name': rawName,
              'price': item['price']?.toString() ?? '0',
              'gst': item['gst_percent']?.toString() ?? '18',
              'barcode': item['barcode'] ?? '',
            });
          }
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _knownProducts = known);
  }

  Future<void> _saveLocalProducts() async {
    await LocalStorageService.saveLocalProducts(_localProducts);
  }

  Future<void> _loadLocalCustomers() async {
    final List<Map<String, dynamic>> known = [];

    try {
      final List<dynamic> customers = await LocalStorageService.loadLocalCustomers();
      for (var c in customers) {
        known.add({
          'name': c['name'] ?? '',
          'phone': c['phone'] ?? '',
          'email': c['email'] ?? '',
          'address': c['address'] ?? '',
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading local customers: $e');
    }

    if (mounted) setState(() => _knownCustomers = known);
  }


  // â”€â”€ Smart Price Learning (USER IDEA) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _updatePriceKnowledge(String barcode, String name, String price, String gst) async {
    // Only learn if the price is a valid relatable number > 0
    double? p = double.tryParse(price);
    if (p == null || p <= 0) return;

    _localProducts[barcode] = {
      'name': name,
      'price': price,
      'gst': gst,
      'barcode': barcode,
      'source': 'Self-Learned (Direct Entry)',
      'region': 'Local Shop'
    };
    await _saveLocalProducts();
    if (kDebugMode) debugPrint('Engine Learned: $name is now ₹$price (GST $gst%)');
  }

  String _getDefaultGst(String name) {
    if (name.isEmpty) return '18';
    final n = name.toLowerCase();
    // Food items -> 5%
    if (n.contains('milk') || n.contains('bread') || n.contains('tea') || n.contains('salt') || 
        n.contains('apple') || n.contains('rice') || n.contains('dal') || n.contains('veggie') || 
        n.contains('fruit') || n.contains('atta') || n.contains('noodle')) {
      return '5';
    }
    // Packaged snacks -> 12%
    if (n.contains('lays') || n.contains('kurkure') || n.contains('pepsi') || n.contains('snack') || 
        n.contains('drink') || n.contains('juice') || n.contains('biscuit') || n.contains('ketchup') || 
        n.contains('butter')) {
      return '12';
    }
    // Personal care & Household -> 18% (Default)
    return '18';
  }

  /// Calculates semantic similarity between two strings using Dice coefficient on bigrams
  /// Returns a score from 0.0 to 1.0
  double _calculateBigramSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    String t1 = s1.toLowerCase().trim();
    String t2 = s2.toLowerCase().trim();
    if (t1 == t2) return 1.0;
    if (t1.length < 2 || t2.length < 2) return 0.0;

    Set<String> getBigrams(String str) {
      final bigrams = <String>{};
      for (int i = 0; i < str.length - 1; i++) {
        bigrams.add(str.substring(i, i + 2));
      }
      return bigrams;
    }

    final b1 = getBigrams(t1);
    final b2 = getBigrams(t2);
    if (b1.isEmpty || b2.isEmpty) return 0.0;

    final intersection = b1.intersection(b2).length;
    return (2.0 * intersection) / (b1.length + b2.length);
  }

  // â”€â”€ Search History for Prices (USER IDEA - Name_Barcode Logic) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<Map<String, dynamic>?> _searchPriceInHistory(String barcode) async {
    final prefs = await SharedPreferences.getInstance();
    final _scopeEmail2 = prefs.getString('email') ?? 'default';
    final historyRaw = prefs.getString('all_sales_$_scopeEmail2') ?? prefs.getString('all_sales');
    if (historyRaw == null) return null;

    try {
      final List<dynamic> allSales = json.decode(historyRaw);

      final List<double> prices = [];
      String? lastCleanName;
      String? lastGst;

      // Walk from newest to oldest; compute a stable average price.
      for (var sale in allSales.reversed) {
        final List<dynamic> items = sale['items'] ?? [];
        for (var item in items) {
          final String itemId = (item['product_id'] ?? item['barcode'] ?? '').toString().trim();
          final String rawItemName = (item['product_name'] ?? item['item'] ?? '').toString().trim();
          final String itemPrice = (item['price'] ?? '0').toString();
          final String itemGst = (item['gst_percent'] ?? item['gst'] ?? '18').toString();

          bool match = (itemId == barcode);

          // Legacy Fallback: check if barcode was embedded in the item name
          String itemName = rawItemName;
          if (!match && itemName.isNotEmpty) {
            if (itemName == barcode || itemName.endsWith('_$barcode')) {
              match = true;
            }
          }

          if (!match) continue;

          final double? p = double.tryParse(itemPrice);
          if (p == null || p <= 0) continue;

          String cleanName = itemName;
          if (cleanName.endsWith('_$barcode')) {
            cleanName = cleanName.substring(0, cleanName.length - barcode.length - 1).trim();
          }
          if (cleanName.isEmpty) cleanName = 'Product $barcode';

          prices.add(p);
          lastCleanName = cleanName; // newest match name
          lastGst = itemGst;
        }
      }

      if (prices.isEmpty) return null;
      final avg = prices.reduce((a, b) => a + b) / prices.length;

      return {
        'name': lastCleanName ?? 'Product $barcode',
        'price': avg.toStringAsFixed(2),
        'gst': lastGst ?? '18',
        'barcode': barcode,
        'source': 'Sales History (Avg)'
      };
    } catch (e) {
      if (kDebugMode) debugPrint('History search error: $e');
    }
    return null;
  }

  Future<void> _handleScannedBarcode(String code) async {
    // 🛑 BARCODE DEBOUNCE (300ms)
    final now = DateTime.now();
    if (_lastScanTime != null && now.difference(_lastScanTime!).inMilliseconds < 300) {
      if (kDebugMode) debugPrint('â© Scanned too fast, ignoring...');
      return;
    }
    _lastScanTime = now;

    // ✨ VISUAL FEEDBACK: Green flash animation
    setState(() => _scanFlashOpacity = 1.0);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _scanFlashOpacity = 0.0);
    });

    // Play scan sound
    SystemSound.play(SystemSoundType.click);
    HapticFeedback.vibrate();
    PaymentAnnouncementService().speakSimple("Ok", _paymentSoundLang);

    // 1. Check Local catalog FIRST (Direct match from shopkeeper's catalog)
    final local = _localProducts[code];
    if (local != null) {
      _applyProductToBill(local);
      ScaffoldMessenger.of(context).showSnackBar(
        _styledSnackBar('Added ${local['name']} from your catalog'),
      );
      return;
    }

    // 2. Check Historical Sales Data (From this shopkeeper's previous sales)
    final historicalPrice = await _searchPriceInHistory(code);
    if (historicalPrice != null && double.tryParse(historicalPrice['price']?.toString() ?? '0') != null && double.parse(historicalPrice['price'].toString()) > 0) {
      _applyProductToBill(historicalPrice);
      ScaffoldMessenger.of(context).showSnackBar(
        _styledSnackBar('Product found in your Sales History'),
      );
      return;
    }

    // 3. Not found in shop's own data
    final emptyProduct = {
      'name': '',
      'price': '0',
      'barcode': code,
      'source': 'Manual Entry'
    };
    
    _applyProductToBill(emptyProduct);
    ScaffoldMessenger.of(context).showSnackBar(
      _styledSnackBar('Product not in your shop records. Please enter manually.', isError: true),
    );
  }

  Future<Map<String, dynamic>?> _lookupProductOnline(String barcode) async {
    if (_globalProductDataset.containsKey(barcode)) {
      final p = _globalProductDataset[barcode];
      if (p == null) return null;
      return {
        'name': p['name'],
        'price': p['price'],
        'gst': p['gst'],
        'barcode': barcode,
        'source': 'Verified Engine',
        'region': barcode.startsWith('890') ? 'India' : 'Global'
      };
    }

    String countryHint = barcode.startsWith('890') ? 'India' : 'Global';

    // â”€â”€ PARALLEL SEARCH ENGINE (Speed Optimized for < 3s) â”€â”€
    try {
      if (kDebugMode) debugPrint('Launching Parallel Search for $barcode...');
      
      final results = await Future.wait([
        _fetchBarcodeLookup(barcode, countryHint),
        _fetchRetailDB(barcode, countryHint),
        _fetchOpenFoodFacts(barcode, countryHint),
      ]).timeout(const Duration(milliseconds: 2800), onTimeout: () => [null, null, null]);

      // Rank results: 
      // 1. Has name and price > 0
      // 2. Has name but 0 price
      // 3. Null
      
      Map<String, dynamic>? bestSub;
      for (var res in results) {
        if (res == null) continue;
        double p = double.tryParse(res['price']?.toString() ?? '0') ?? 0;
        if (res['name'].toString().isNotEmpty && p > 0) {
          return res; // Perfect match
        }
        if (res['name'].toString().isNotEmpty && bestSub == null) {
          bestSub = res; // Save for fallback
        }
      }
      return bestSub;
    } catch (e) {
      if (kDebugMode) debugPrint('Parallel search engine failed: $e');
    }

    return null;
  }

  Future<Map<String, dynamic>?> _fetchBarcodeLookup(String barcode, String countryHint) async {
    try {
      // NOTE: barcodelookup.com requires an API key to function.
      // Replace 'YOUR_API_KEY' with a valid key when deploying to production, 
      // or set via environment variable.
      const apiKey = String.fromEnvironment('BARCODELOOKUP_API_KEY', defaultValue: '');
      if (apiKey.isEmpty) return null; // Fail fast if no key
      
      final blUrl = 'https://api.barcodelookup.com/v3/products?barcode=$barcode&key=$apiKey';
      final res = await http.get(Uri.parse(blUrl)).timeout(const Duration(milliseconds: 2500));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['products'] != null && data['products'].isNotEmpty) {
          final p = data['products'][0];
          return {
            'name': p['product_name'] ?? '',
            'price': '0',
            'gst': _getDefaultGst(p['product_name'] ?? ''),
            'barcode': barcode,
            'source': 'Global Engine 1',
            'region': countryHint
          };
        }
      }
    } catch (e) {}
    return null;
  }

  Future<Map<String, dynamic>?> _fetchRetailDB(String barcode, String countryHint) async {
    try {
      final upcUrl = 'https://api.upcitemdb.com/prod/trial/lookup?upc=$barcode';
      final res = await http.get(Uri.parse(upcUrl)).timeout(const Duration(milliseconds: 2500));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['items'] != null && data['items'].isNotEmpty) {
          final item = data['items'][0];
          return {
            'name': item['title'] ?? '',
            'price': '0',
            'gst': _getDefaultGst(item['title'] ?? ''),
            'barcode': barcode,
            'source': 'Global Engine 2',
            'region': countryHint
          };
        }
      }
    } catch (e) {}
    return null;
  }

  Future<Map<String, dynamic>?> _fetchOpenFoodFacts(String barcode, String countryHint) async {
    try {
      final offUrl = 'https://world.openfoodfacts.org/api/v0/product/$barcode.json';
      final offRes = await http.get(Uri.parse(offUrl)).timeout(const Duration(milliseconds: 2500));
      if (offRes.statusCode == 200) {
        final offData = json.decode(offRes.body);
        if (offData['status'] == 1) {
          final pDict = offData['product'];
          String name = (pDict['product_name'] ?? pDict['generic_name'] ?? '').toString();
          if (name.contains('_')) name = name.split('_').first;
          String qty = (pDict['quantity'] ?? pDict['net_weight'] ?? '').toString();
          if (qty.isNotEmpty) name = '$name $qty';
          return {
            'name': name,
            'price': '0',
            'gst': _getDefaultGst(name),
            'barcode': barcode,
            'source': 'Global Engine 3',
            'region': countryHint
          };
        }
      }
    } catch (e) {}
    return null;
  }

  void _applyProductToBill(Map<String, dynamic> product) {
    if (entries.isEmpty) addEntry();
    Map<String, TextEditingController>? target;

    final String scanCode = (product['barcode'] ?? '').toString().trim();
    int targetIndex = -1;

    // 1ï¸âƒ£ SMART MATCHING: Priority Barcode (Structured or Legacy)
    if (scanCode.isNotEmpty) {
      for (int i = 0; i < entries.length; i++) {
        final e = entries[i];
        String storedBarcode = (e['barcode']?.text ?? '').trim();
        
        // 🧪 Deep Match: Check if barcode is stored inside the item name (Legacy cleanup)
        if (storedBarcode.isEmpty) {
          String itemName = e['item']?.text?.trim() ?? '';
          if (itemName.endsWith('_$scanCode') || itemName == scanCode) {
            storedBarcode = scanCode;
          }
        }

        if (storedBarcode == scanCode) {
          target = e;
          targetIndex = i;
          break;
        }
      }
    }

    // 2ï¸âƒ£ Match by name if no barcode match
    if (target == null) {
      String pName = (product['name']?.toString() ?? '').trim().toLowerCase();
      // Legacy cleanup for search query
      if (pName.contains('_') && scanCode.isNotEmpty && pName.endsWith(scanCode)) {
        pName = pName.substring(0, pName.lastIndexOf('_')).trim();
      }
      
      if (pName.isNotEmpty && !['product', 'retail product', 'unknown'].contains(pName)) {
        for (int i = 0; i < entries.length; i++) {
          final e = entries[i];
          String entryName = e['item']?.text?.trim().toLowerCase() ?? '';
          // Legacy cleanup for existing entry name
          if (entryName.contains('_')) {
             final parts = entryName.split('_');
             if (parts.length > 1 && parts.last.length >= 8) {
                entryName = entryName.substring(0, entryName.lastIndexOf('_')).trim();
             }
          }

          if (entryName == pName) {
            target = e;
            targetIndex = i;
            break;
          }
        }
      }
    }

    // 3ï¸âƒ£ Match empty slot
    if (target == null) {
      for (int i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (e['item']?.text.trim().isEmpty ?? true && (e['barcode']?.text.trim().isEmpty ?? true)) {
          target = e;
          targetIndex = i;
          break;
        }
      }
    }

    // 4ï¸âƒ£ Create new slot
    if (target == null) {
      addEntry();
      target = entries.last;
      targetIndex = entries.length - 1;
    }

    // â”€â”€ APPLY DATA â”€â”€
    setState(() {
      _lastAddedRowIndex = targetIndex;
      
      String cleanName = (product['name']?.toString() ?? '').trim();
      // Only strip if it ends with the barcode to avoid truncating names with underscores
      if (scanCode.isNotEmpty && cleanName.endsWith('_$scanCode')) {
        cleanName = cleanName.substring(0, cleanName.length - scanCode.length - 1);
      } else if (cleanName.contains('_')) {
        // Fallback for when name has barcode but maybe slightly different format
        String lastPart = cleanName.split('_').last;
        if (lastPart == scanCode) {
           cleanName = cleanName.substring(0, cleanName.lastIndexOf('_'));
        }
      }
      
      if (target != null && target['item'] != null && target['item']!.text.isEmpty) {
        target['item']!.text = cleanName;
        if (target['qty'] != null) {
          target['qty']!.text = '1';
        }
      } else if (target != null && target['qty'] != null) {
        int currentQty = int.tryParse(target['qty']!.text) ?? 1;
        target['qty']!.text = (currentQty + 1).toString();
      }

      if (scanCode.isNotEmpty && target != null) {
        if (target['barcode'] == null) {
          target['barcode'] = TextEditingController(text: scanCode);
        } else {
          target['barcode']!.text = scanCode;
        }
      }

      double priceValue = double.tryParse(product['price']?.toString() ?? '0') ?? 0;
      if (priceValue > 0 && target != null && target['price'] != null) {
        target['price']!.text = priceValue.toString();
      } else if (target != null && target['price'] != null) {
        // If price is 0 (new product/new user), we clear it or set to empty
        // so the 'Enter Price' validation is triggered and user is forced to enter it.
        target['price']!.text = '';
      }

      String gstValue = (product['gst'] ?? _getDefaultGst(cleanName)).toString();
      if (target != null && target['gst'] == null) {
        target['gst'] = TextEditingController(text: gstValue);
      } else if (target != null && target['gst'] != null) {
        target['gst']!.text = gstValue;
      }

      calculateTotal();
      HapticFeedback.mediumImpact();
    });

    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _lastAddedRowIndex = null);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // Remove lifecycle observer
    // FIX-2: Dispose _speechToText resources before cleanup
    _speechToText.stop();
    _speechToText.cancel();

    PaymentDetectionService().clearBill();
    _paymentSubscription?.cancel();
    _totalPulseController.dispose();
    _entranceController.dispose();
    // Dispose voice pulse controllers
    for (var controller in _voicePulseControllers) {
      controller.dispose();
    }
    customerPhoneController.dispose();
    
    // Safe disposal with null checks
    for (var entry in entries) {
      entry['item']?.dispose();
      entry['qty']?.dispose();
      entry['price']?.dispose();
      entry['gst']?.dispose();
      entry['barcode']?.dispose();
      entry['discount']?.dispose(); // Added missing discount controller disposal
    }
    
    _dueDateController.dispose();
    super.dispose();
  }

  // 🔧 FIX: Handle app lifecycle changes - OFFLINE-FIRST MODE
  // No longer forces logout on app resume - session persists indefinitely
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (kDebugMode) debugPrint('🔄 App resumed - session persists (offline-first mode)');
      // No session refresh needed - user stays logged in
      // Re-check notification-access permission when the user comes back
      // from Settings — this is what makes the inline "Enable" button (and
      // the "TRIPLE-CHANNEL DETECTION ACTIVE" banner) update immediately
      // instead of staying stale until the page is reopened.
      _recheckNotificationPermission();
    }
  }

  // 🔧 FIX: Session check - OFFLINE-FIRST MODE
  // No longer shows session expired warnings - session persists indefinitely
  Future<void> _refreshSessionIfNeeded() async {
    try {
      final tokenValid = await SessionManagementService.isTokenValid();
      if (tokenValid) {
        if (kDebugMode) debugPrint('✅ Session valid - user stays logged in');
      } else {
        if (kDebugMode) debugPrint('⚠️ No valid session - user needs to login');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Session check error: $e');
    }
  }
  
  // 🔒 DATA VALIDATION: Validate sale data before saving
  Future<bool> _validateSaleData() async {
    if (entries.isEmpty) {
      if (mounted) setState(() => message = 'Please add at least one item');
      return false;
    }
    
    // Validate each entry
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final itemName = entry['item']?.text?.trim();
      final qtyText = entry['qty']?.text?.trim();
      final priceText = entry['price']?.text?.trim();
      
      // Check required fields
      if (itemName == null || itemName.isEmpty) {
        if (mounted) setState(() => message = 'Item ${i + 1} is missing name');
        return false;
      }
      
      if (qtyText == null || qtyText.isEmpty) {
        if (mounted) setState(() => message = 'Item ${i + 1} is missing quantity');
        return false;
      }
      
      if (priceText == null || priceText.isEmpty) {
        if (mounted) setState(() => message = 'Item ${i + 1} is missing price');
        return false;
      }
      
      // Validate numeric values
      final quantity = int.tryParse(qtyText);
      if (quantity == null || quantity <= 0) {
        if (mounted) setState(() => message = 'Item ${i + 1} has invalid quantity: $qtyText');
        return false;
      }
      
      final price = double.tryParse(priceText);
      if (price == null || price < 0) {
        if (mounted) setState(() => message = 'Item ${i + 1} has invalid price: $priceText');
        return false;
      }
      
      // Validate GST if enabled
      if (_withTax) {
        final gstText = entry['gst']?.text?.trim();
        if (gstText != null && gstText.isNotEmpty) {
          final gst = double.tryParse(gstText);
          if (gst == null || gst < 0 || gst > 30) {
            if (mounted) setState(() => message = 'Item ${i + 1} has invalid GST rate: $gstText');
            return false;
          }
        }
      }
    }
    
    // Validate customer if provided
    final customerPhone = customerPhoneController.text.trim();
    if (customerPhone.isNotEmpty) {
      if (!RegExp(r'^[0-9]{10}$').hasMatch(customerPhone)) {
        if (mounted) setState(() => message = 'Invalid phone number format (10 digits required)');
        return false;
      }
    }
    
    return true;
  }
  
  // 🔒 STOCK VALIDATION: Check stock availability before sale
  Future<bool> _validateStockAvailability() async {
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final itemName = entry['item']?.text?.trim();
      final qtyText = entry['qty']?.text?.trim();
      
      if (itemName == null || itemName.isEmpty || qtyText == null || qtyText.isEmpty) {
        continue;
      }
      
      final quantity = int.tryParse(qtyText) ?? 0;
      if (quantity <= 0) continue;
      
      try {
        final validation = await StockValidationService.instance.validateItemStock(
          itemName: itemName,
          requestedQuantity: quantity,
        );
        
        if (!validation.isValid) {
          if (mounted) {
            setState(() => message = validation.message);
          }
          return false;
        }
        
        if (validation.requiresManualConfirmation) {
          if (kDebugMode) debugPrint('⚠️ Stock validation requires manual confirmation: ${validation.message}');
          // Continue but log warning
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Stock validation failed for $itemName: $e');
        // Continue with validation failure warning
        if (mounted) {
          setState(() => message = 'Could not validate stock for $itemName. Proceed with caution.');
        }
      }
    }
    
    return true;
  }



  // â”€â”€ HYBRID: Partial Cash Dialog â”€â”€
  void _showPartialCashDialog() {
    final TextEditingController amountController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Record Cash Payment (₹)', 
                   style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remaining Due: ₹${(totalAmount - _paidAmount).toStringAsFixed(2)}', 
                 style: GoogleFonts.poppins(fontSize: 13, color: Colors.redAccent, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black),
              decoration: InputDecoration(
                hintText: 'Enter cash amount',
                prefixText: '₹ ',
                prefixStyle: GoogleFonts.poppins(color: Colors.black54, fontWeight: FontWeight.bold),
                filled: true,
                isDense: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), 
                                                 borderSide: const BorderSide(color: Color(0xFF10B981), width: 2)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: Text('CANCEL', style: GoogleFonts.poppins(color: Colors.grey, fontWeight: FontWeight.w600))
          ),
          ElevatedButton(
            onPressed: () {
              final val = double.tryParse(amountController.text) ?? 0.0;
              if (val > 0) {
                final double currentTotal = totalAmount;
                setState(() {
                  _paidAmount += val;
                  if (_paidAmount >= currentTotal - 0.5) {
                    _paidAmount = currentTotal;
                    _paymentConfirmed = true;
                  }
                });
                Navigator.pop(ctx);
                
                // Voice Announcement for the received cash portion
                final double remaining = (currentTotal - _paidAmount) < 0.1 ? 0.0 : (currentTotal - _paidAmount);
                if (remaining > 0) {
                   PaymentAnnouncementService().announceReceipt(
                    amount: val, 
                    language: _paymentSoundLang, 
                    mode: _announcementMode,
                    isPartial: true,
                    remaining: remaining,
                  );
                } else {
                   PaymentAnnouncementService().announceReceipt(
                    amount: val, 
                    language: _paymentSoundLang, 
                    mode: _announcementMode,
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: Text('ADD CASH', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // Add lifecycle observer
    PrinterService.autoConnect();
    addEntry();
    _loadLocalProducts();
    _loadLocalCustomers();
    
    // 🔧 FIX: Refresh session when app starts to ensure authentication is valid
    _refreshSessionIfNeeded();
    
    // 🔄 Auto-sync queued actions when app starts
    _processSyncQueue();
    
    // ✅ Periodic sync check every 30 seconds
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) _processSyncQueue();
    });

    // Optimized: Unused animations removed for better performance on small phones
    _totalPulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _totalPulse = Tween<double>(begin: .6, end: 1.0).animate(
      CurvedAnimation(parent: _totalPulseController, curve: Curves.easeInOut),
    );

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _entranceFade =
        CurvedAnimation(parent: _entranceController, curve: Curves.easeOut);
    _entranceSlide = Tween<Offset>(
            begin: const Offset(0, .06), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _entranceController, curve: Curves.easeOutCubic));
    _entranceController.forward();

    // Initialize voice pulse controllers
    _voicePulseControllers = List.generate(3, (i) => AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    ));
    
    // Start them with staggered delays
    for (int i = 0; i < _voicePulseControllers.length; i++) {
      Future.delayed(Duration(milliseconds: i * 500), () {
        if (mounted) {
          _voicePulseControllers[i].repeat();
        }
      });
    }
    _loadPaymentConfig();
    _checkPaymentPermissions();
  }

  Future<void> _checkPaymentPermissions() async {
    // Avoid double prompting if already shown in Dashboard
    await Future.delayed(const Duration(milliseconds: 2000));
    if (!mounted) return;

    bool hasNotif = await PaymentDetectionService.hasNotificationPermission();
    if (mounted) setState(() => _hasNotifPermission = hasNotif);
    if (!hasNotif && mounted) {
      _showPermissionDialog(
        title: 'Auto-Pay Active',
        desc: 'Detect UPI payments instantly. 🔒 We only process payment apps (PhonePe/GPay) to protect your privacy.',
        onConfirm: () => _openNotificationSettingsAndRecheck(),
      );
    }
  }

  // BUG FIX: previously the ONLY way to grant notification access was this
  // one-off dialog shown 2s after opening the page — if the user tapped
  // "LATER" or dismissed it, there was no button anywhere on this screen to
  // try again, so payment auto-detection silently stayed broken forever.
  // `_hasNotifPermission` now also drives a persistent inline button (see
  // the "Listening for UPI, SMS & Screen..." section below).
  Future<void> _openNotificationSettingsAndRecheck() async {
    await PaymentDetectionService.openNotificationSettings();
    // The user grants/denies access inside Android Settings, not inside the
    // app, so re-check as soon as they come back (also re-checked on app
    // resume via didChangeAppLifecycleState as a safety net).
    await _recheckNotificationPermission();
  }

  Future<void> _recheckNotificationPermission() async {
    try {
      final hasNotif = await PaymentDetectionService.hasNotificationPermission();
      if (mounted) setState(() => _hasNotifPermission = hasNotif);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Notification permission recheck failed: $e');
    }
  }

  void _showPermissionDialog({required String title, required String desc, required VoidCallback onConfirm}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
        title: Row(
          children: [
            const Icon(Icons.notifications_active, color: Color(0xFF10B981)),
            const SizedBox(width: 12),
            Text(title, style: GoogleFonts.poppins(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(desc, style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('LATER', style: GoogleFonts.poppins(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              onConfirm();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('ENABLE', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _loadPaymentConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _upiId = prefs.getString('upi_id');
      _shopNameForDynamicQr = prefs.getString('shop_name') ?? 'Retail Shop';
      _paymentSoundEnabled = prefs.getBool('payment_sound_enabled') ?? true;
      _paymentSoundLang = prefs.getString('payment_sound_lang') ?? 'en-US';
      _speechInputLang = prefs.getString('speech_input_lang') ?? _paymentSoundLang;
      final modeIndex = prefs.getInt('announcement_mode') ?? 1; // 1 = shopkeeper
      _announcementMode = AnnouncementMode.values[modeIndex];
    });

    // Start automatic payment detection (Singleton Stream)
    if (_paymentSoundEnabled) {
      // FIX-UPI-LOOP: Assign a new session ID for this bill so stale LIKELY
      // re-announce events from a previously completed bill are discarded.
      _billSessionId = DateTime.now().microsecondsSinceEpoch.toString();
      final String capturedSessionId = _billSessionId;

      _paymentSubscription?.cancel();
      _paymentSubscription = PaymentDetectionService().onPaymentDetected.listen((event) {
        if (!mounted) return;

        // FIX-UPI-LOOP: Discard events that belong to a stale bill session.
        // This prevents LIKELY re-announce timers (from _scheduleLikelyReannounce)
        // from triggering the UPI prompt on a brand-new blank bill.
        if (capturedSessionId != _billSessionId) {
          if (kDebugMode) debugPrint('⚠️ Stale session event discarded (session changed): ${event.fingerprint}');
          return;
        }

        // 🔴 Force fresh total calculation synchronously
        final Map<String, double> totals = calculateTotal();
        final double freshTotal = totals['total'] ?? 0.0;

        // FIX-UPI-LOOP: Only process payment if the current bill has items entered.
        // This prevents the UPI prompt loop when the shopkeeper opens a blank new
        // bill and a stale UPI notification re-fires from the detection engine.
        if (freshTotal <= 0) {
          if (kDebugMode) debugPrint('⚠️ Payment event ignored — no active bill (total=0): ${event.fingerprint}');
          return;
        }

        // 🛑 CRITICAL: Deduplicate payment events (Idempotency)
        if (_processedPaymentIds.contains(event.fingerprint)) {
          if (kDebugMode) debugPrint('⚠️ Payment event already processed: ${event.fingerprint}');
          return;
        }
        _processedPaymentIds.add(event.fingerprint);
        // FIX-1: Cap at 100 entries, FIFO rollover
        if (_processedPaymentIds.length > 100) {
          _processedPaymentIds.remove(_processedPaymentIds.first);
        }

        // 🟢 Handle Success/Failure Logic
        setState(() {
          // FIX-UPI-LOOP: Only switch to Online/UPI mode if bill has items (freshTotal > 0).
          // Previously this unconditionally set _isOnlinePayment = true causing blank
          // bills to switch mode and show the payment waiting UI repeatedly.
          if (freshTotal > 0) {
            _isOnlinePayment = true;
          }

          // Add to History (keep last 5)
          _recentHistory.insert(0, event);
          if (_recentHistory.length > 5) _recentHistory.removeLast();

          if (!event.isFailed) {
            _paidAmount += event.amount;

            // Precision match (ignore small paisa diff)
            // CRITICAL: Only confirm if totalAmount is actually > 0
            if (freshTotal > 0) {
              if ((freshTotal - _paidAmount).abs() < 0.01) {
                _paidAmount = freshTotal;
                _paymentConfirmed = true;
              } else if (_paidAmount >= freshTotal - 0.005) {
                _paymentConfirmed = true;
              }
            } else {
              // If total is 0, we can't confirm full payment yet
              _paymentConfirmed = false;
            }
          }
        });

        // UI Feedback only — Announcement is handled by the Detection Engine
        if (!mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(event.isFailed ? 'âŒ PAYMENT FAILED' : (_paymentConfirmed
                ? '✅ RECEIVED ₹${event.amount.toStringAsFixed(0)} (Full)'
                : '⚠️ RECEIVED ₹${event.amount.toStringAsFixed(0)} | ₹${(freshTotal - _paidAmount).toStringAsFixed(0)} Left')),
            backgroundColor: event.isFailed ? Colors.red : (_paymentConfirmed ? const Color(0xFF10B981) : Colors.orange.shade800),
          ),
        );
      });
    }
  }
  void _showFullScreenQr(Uint8List bytes) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                   Text(
                    'Customer Scan QR',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.black54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Container(
              padding: const EdgeInsets.all(30),
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '₹${totalAmount.toStringAsFixed(2)}',
                    style: GoogleFonts.spaceMono(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'PAYMENT AMOUNT',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      letterSpacing: 2,
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Color(0xFF22C55E).withValues(alpha: 0.05),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.verified_user, color: Color(0xFF22C55E), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Secure Automatic Payment Detection Active',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: const Color(0xFF166534),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // â”€â”€ Logic (unchanged) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void addEntry() {
    setState(() {
      entries.add({
        'item': TextEditingController(),
        'qty': TextEditingController(text: '1'), // Default to 1 for shopkeeper speed
        'price': TextEditingController(),
        'gst': TextEditingController(text: '18'),
        'barcode': TextEditingController(),
        'discount': TextEditingController(text: '0'), // Added per-item discount
      });
      _hapticLight();
    });
  }

  void removeEntry(int index) {
    if (entries.length > 1) {
      // 🛑 CRITICAL: Dispose controllers to prevent memory leaks
      final entry = entries[index];
      entry['item']?.dispose();
      entry['qty']?.dispose();
      entry['price']?.dispose();
      entry['gst']?.dispose();
      entry['barcode']?.dispose();
      entry['discount']?.dispose();

      setState(() {
        entries.removeAt(index);
        calculateTotal();
        _hapticMedium();
      });
    }
  }

  // Looks up any active flash sale from SharedPreferences (async), applies it
  // to _flashSaleDiscount, and re-runs calculateTotal() so the displayed
  // total picks up the discount once it's known.
  Future<void> _applyFlashSaleDiscount(double subTotal) async {
    double flashSaleDiscount = 0.0;
    try {
      final flashSaleData = await ScopedSharedPreferences.getString('active_flash_sale');
      if (flashSaleData != null && flashSaleData.isNotEmpty) {
        final dynamic decoded = jsonDecode(flashSaleData);
        if (decoded is! Map) throw const FormatException('Invalid flash sale payload');
        final sale = Map<String, dynamic>.from(decoded);
        final status = (sale['status'] ?? 'ACTIVE').toString().trim().toUpperCase();
        final expiry = DateTime.tryParse(sale['expiry']?.toString() ?? '');
        if (status != 'ACTIVE') {
          await ScopedSharedPreferences.remove('active_flash_sale');
          if (mounted && _flashSaleDiscount != 0) setState(() => _flashSaleDiscount = 0);
          return;
        }
        if (expiry == null || !DateTime.now().isBefore(expiry)) {
          await ScopedSharedPreferences.remove('active_flash_sale');
        } else {
          final pct = (double.tryParse(sale['discount']?.toString() ?? '0') ?? 0).clamp(0, 100);
          final singleCategory = sale['category']?.toString().trim().toLowerCase() ?? '';
          final categories = (sale['categories'] as List?)?.map((e) => e.toString().trim().toLowerCase()).toSet() ?? <String>{};
          if (singleCategory.isNotEmpty) categories.add(singleCategory);
          final productIds = (sale['product_ids'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
          final skus = (sale['skus'] as List?)?.map((e) => e.toString().trim().toLowerCase()).toSet() ?? <String>{};
          final products = await LocalStorageService.loadBackendProducts();
          double eligible = 0;

          for (final entry in entries) {
            final name = entry['item']?.text?.trim() ?? '';
            final barcode = entry['barcode']?.text?.trim() ?? '';
            final qty = double.tryParse(entry['qty']?.text?.trim() ?? '1') ?? 1;
            final price = double.tryParse(entry['price']?.text?.trim() ?? '0') ?? 0;
            final line = math.max(0, qty * price);
            if (line <= 0) continue;
            final product = products.cast<Map<String, dynamic>>().firstWhere(
              (p) => p['id']?.toString() == barcode ||
                     p['product_id']?.toString() == barcode ||
                     p['sku']?.toString().toLowerCase() == barcode.toLowerCase() ||
                     p['product_name']?.toString().toLowerCase() == name.toLowerCase(),
              orElse: () => <String, dynamic>{},
            );
            final id = product['id']?.toString() ?? product['product_id']?.toString() ?? barcode;
            final sku = product['sku']?.toString().toLowerCase() ?? barcode.toLowerCase();
            final category = product['category']?.toString().trim().toLowerCase() ?? '';
            final eligibleLine = productIds.isNotEmpty
                ? productIds.contains(id)
                : skus.isNotEmpty
                    ? skus.contains(sku)
                    : categories.isNotEmpty
                        ? categories.contains(category)
                        : true;
            if (eligibleLine) eligible += line;
          }
          flashSaleDiscount = eligible * (pct / 100);
          if (kDebugMode) debugPrint('✅ Scoped Flash Sale discount: $pct% = ₹$flashSaleDiscount');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error applying flash sale discount: $e');
    }
    if (mounted && flashSaleDiscount != _flashSaleDiscount) {
      setState(() => _flashSaleDiscount = flashSaleDiscount);
      calculateTotal();
    }
  }

  Map<String, double> calculateTotal() {
    double subTotal = 0.0;
    double gstTotal = 0.0;

    for (var entry in entries) {
      final String qtyText = entry['qty']?.text.trim() ?? '1';
      final String priceText = entry['price']?.text.trim() ?? '0';
      final String discText = entry['discount']?.text.trim() ?? '0';

      final double qty = qtyText.isEmpty ? 1.0 : (double.tryParse(qtyText) ?? 0.0);
      final double price = double.tryParse(priceText) ?? 0.0;
      final double discount = double.tryParse(discText) ?? 0.0;
      final double gstPct = double.tryParse(entry['gst']?.text ?? '0') ?? 0.0;

      final double effectivePrice = math.max(0.0, price - discount);
      final double lineSubtotal = qty * effectivePrice;
      
      subTotal += lineSubtotal;
      if (_withTax) {
        gstTotal += lineSubtotal * (gstPct / 100);
      }
    }

    final double cgst = double.parse((gstTotal / 2).toStringAsFixed(2));
    final double sgst = double.parse((gstTotal / 2).toStringAsFixed(2));
    double grand = double.parse((subTotal + gstTotal).toStringAsFixed(2));

    // Apply best scheme discount
    try {
      final schemeItems = entries
          .where((e) => e['item']?.text.isNotEmpty ?? false)
          .map((e) => {
            'quantity': double.tryParse(e['qty']?.text ?? '1') ?? 1,
            'price': double.tryParse(e['price']?.text ?? '0') ?? 0,
            'product_name': e['item']?.text ?? '',
          })
          .toList();

      final schemeResult =
          SchemeEngine.applyBestScheme(schemeItems, subTotal);

      if (mounted) {
        setState(() {
          _schemeDiscount = (schemeResult['discount_amount'] as num?)?.toDouble() ?? 0;
          _activeSchemeName = schemeResult['scheme_name']?.toString() ?? '';
        });
      }

      // Flash sale discount requires an async SharedPreferences lookup, so it
      // can't be resolved inside this synchronous method. Kick it off here;
      // once it resolves, it updates _flashSaleDiscount and triggers a
      // recalculation so the total reflects it.
      _applyFlashSaleDiscount(subTotal);

      final totalDiscount = _schemeDiscount + _flashSaleDiscount;
      if (totalDiscount > 0) {
        grand = double.parse(((subTotal + gstTotal - totalDiscount)).toStringAsFixed(2));
      }
    } catch (e) {
      // Keep the deterministic normal total, but surface the failed scheme
      // evaluation in diagnostics instead of silently hiding it.
      if (kDebugMode) debugPrint('⚠️ Scheme calculation failed; using normal total: $e');
      _schemeDiscount = 0.0;
      _activeSchemeName = '';
    }

    if (mounted) {
      setState(() {
        totalSubtotal = double.parse(subTotal.toStringAsFixed(2));
        totalCgst     = cgst;
        totalSgst     = sgst;
        totalAmount   = grand;
      });
      
      if (grand > 0) {
        PaymentDetectionService().setBillExpected(grand);
      } else {
        PaymentDetectionService().clearBill();
      }
    }
    
    return {
      'subtotal': subTotal,
      'cgst': cgst,
      'sgst': sgst,
      'total': grand,
    };
  }

  void _clearSaleInterface() {
    if (!mounted) return;
    
    setState(() {
      // 🛑 MEMORY LEAK PREVENTION: Dispose existing controllers before clearing list
      for (var entry in entries) {
        entry['item']?.dispose();
        entry['qty']?.dispose();
        entry['price']?.dispose();
        entry['gst']?.dispose();
        entry['barcode']?.dispose();
        entry['discount']?.dispose();
      }
      entries.clear(); // Explicitly clear after disposal

      customerPhoneController.clear();
      customerNameController.clear();
      _paidAmount = 0;
      _paymentConfirmed = false;
      // FIX-UPI-LOOP: Reset to Cash mode on new bill so the UPI waiting UI doesn't
      // show immediately on blank bills. The shopkeeper can manually switch to UPI
      // or it will auto-switch when a real payment arrives for the new bill.
      _isOnlinePayment = false;
      // FIX-UPI-LOOP: Rotate session ID so the listener closure capturedSessionId
      // no longer matches, instantly discarding all stale LIKELY re-announce events.
      _billSessionId = DateTime.now().microsecondsSinceEpoch.toString();
      totalAmount = 0; // 🔴 FIX: Reset display amount to zero after save
      message = 'Transaction successfully recorded! ✅';

      // Re-initialize with a single fresh entry
      entries = [
        {
          'item': TextEditingController(),
          'qty': TextEditingController(text: '1'),
          'price': TextEditingController(),
          'gst': TextEditingController(text: '18'),
          'barcode': TextEditingController(),
          'discount': TextEditingController(text: '0'),
        }
      ];
    });
  }

  // â”€â”€ REFACTORED MODULES FOR SUBMISSION â”€â”€

  bool _validateSaleInputs(double total) {
    if (!(_formKey.currentState?.validate() ?? false)) {
      if (mounted) setState(() => message = 'Please fix errors before confirming.');
      return false;
    }

    final nonEmpty = entries.where((e) => e['item']?.text.trim().isNotEmpty ?? false).toList();
    if (nonEmpty.isEmpty) {
      if (mounted) setState(() => message = 'Please add at least one item.');
      return false;
    }

    // STRICT VALIDATION: No ₹0 or negative prices, and no zero quantity
    for (var entry in nonEmpty) {
       final price = double.tryParse(entry['price']?.text.trim() ?? '0') ?? 0;
       final qty = double.tryParse(entry['qty']?.text.trim() ?? '0') ?? 0;
       if (price <= 0) {
          if (mounted) {
            setState(() => message = 'Item "${entry['item']?.text}" has no price! ₹0 sales are blocked.');
          }
          return false;
       }
       if (qty <= 0) {
          if (mounted) {
            setState(() => message = 'Item "${entry['item']?.text}" has invalid quantity.');
          }
          return false;
       }
    }

    return true;
  }

  List<Map<String, dynamic>> _getProcessedItems() {
    return entries.where((e) => e['item']?.text.trim().isNotEmpty ?? false).map((e) {
      final barcode   = e['barcode']?.text.trim() ?? '';
      final rawName   = e['item']?.text.trim() ?? '';
      final qty       = double.tryParse(e['qty']?.text.trim() ?? '1') ?? 1.0;
      final price     = double.tryParse(e['price']?.text.trim() ?? '0') ?? 0.0;
      final gstPct    = double.tryParse(e['gst']?.text.trim() ?? '0') ?? 0.0;
      
      final lineSub   = qty * price;
      final lineGst   = _withTax ? lineSub * (gstPct / 100) : 0.0;
      final lineTotal = double.parse((lineSub + lineGst).toStringAsFixed(2));

      // Try to find the exact matching product ID from 'known' list
      final nameLower = rawName.toLowerCase();
      final match = _knownProducts.firstWhere(
          (p) => p['name'].toString().toLowerCase() == nameLower || (barcode.isNotEmpty && p['barcode'].toString() == barcode), 
          orElse: () => {}
      );
      final realProductId = match.isNotEmpty ? (match['id'] ?? barcode) : barcode;

      return {
        'product_name': rawName,
        'product_id':   realProductId, 
        'barcode':      barcode,
        'price':        price.toString(),
        'qty':          qty,
        'quantity':     qty,
        'gst_percent':  gstPct.toString(),
        'total_with_tax': lineTotal.toString(),
        'item_index':   entries.indexOf(e),
      };
    }).toList();
  }

  Future<bool> submitAllSales({bool isBorrow = false}) async {
    if (isLoading) return false;

    // FIX: isLoading used to only get set to true after two awaited calls
    // below (session check + loadSales). A fast double-tap on the bill
    // button could get a second call past the `if (isLoading) return false`
    // guard before the first call had set the flag, and since saleId is
    // generated fresh per call (microsecond timestamp), SaleService's
    // idempotency check — keyed by saleId — never saw them as duplicates.
    // Setting isLoading synchronously here, before any await, closes that
    // window: the second tap now sees isLoading == true immediately.
    setState(() {
      isLoading = true;
      message = 'Processing Transaction...';
    });

    // 🔧 FIX: Check local session validity (7-day timestamp check)
    // Note: ApiClient will handle auto-refresh on 401 errors automatically
    try {
      final tokenValid = await SessionManagementService.isTokenValid();
      if (!tokenValid) {
        if (kDebugMode) debugPrint('🔐 Session expired (older than 7 days)');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Session expired. Please login again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        // FIX: reset the flag we now set up-front (see comment above), or
        // the bill button stays permanently disabled after this bounce.
        if (mounted) setState(() => isLoading = false);
        return false;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Session check error: $e');
      // Continue anyway - ApiClient will handle token refresh on 401
    }

    final totals = calculateTotal() as Map<String, dynamic>;
    final grandTotal = totals['total'] ?? 0.0;

    if (!_validateSaleInputs(grandTotal)) {
      // FIX: reset isLoading here too — same reason as above.
      if (mounted) setState(() => isLoading = false);
      return false;
    }

    // First-sale celebration: detect if this is the first bill on this device/user.
    // (Helps D1→D7 retention; backend sync can happen later.)
    final bool isFirstSaleForThisShop = (await LocalStorageService.loadSales()).isEmpty;

    // Generate unique ID for this sale using Microseconds for absolute collision avoidance
    final saleId = 'SALE_${DateTime.now().microsecondsSinceEpoch}';

    try {
      final items = _getProcessedItems();
      final result = await SaleService.submitSale(
        saleId: saleId,
        items: items,
        grandTotal: grandTotal,
        paidAmount: isBorrow ? 0.0 : _paidAmount, // Borrow: paidAmount = 0
        customerName: customerNameController.text.trim(),
        customerPhone: customerPhoneController.text.trim(),
        withTax: _withTax,
        totals: totals,
        paymentMethod: _isOnlinePayment ? 'Online' : 'Cash', // NEW: Pass payment type
        isBorrow: isBorrow, // NEW: Pass borrow flag to use correct endpoint
      );

      // If it's a borrow sale, also create an invoice!
      if (isBorrow) {
        // Reuse the canonical sale id as the invoice identity.
        // SaleService already syncs borrow sales with saleId as the backend
        // idempotency key. Keep this local mirror on that same canonical id.
        final String invoiceNumber = saleId;
        
        // Build product list string for invoice
        final String productList = items.map((e) {
          final qtyRaw = e['qty'];
          final qty = qtyRaw is num ? qtyRaw : double.tryParse(qtyRaw?.toString() ?? '1') ?? 1;
          return '${e['product_name']} ($qty x ₹${e['price']})';
        }).join(', ');
        
        // Due date from borrow selection
        final String dueDate = _selectedDueDate != null 
          ? DateFormat('yyyy-MM-dd').format(_selectedDueDate!) 
          : DateFormat('yyyy-MM-dd').format(DateTime.now().add(const Duration(days: 7)));
        
        // Create invoice object
        final newInvoice = {
          'invoice_number': invoiceNumber,
          'product': productList,
          'customer_name': customerNameController.text.trim(),
          'customer_phone': customerPhoneController.text.trim(),
          'total_amount': grandTotal,
          'paid_amount': 0.0,
          'due_date': dueDate,
          'status': 'UNPAID',
          'payment_status': 'UNPAID',
          'is_local': result['status'] != 'SYNCED',
          'business_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'sale_id': saleId,
        };
        
        // Save a local mirror; SaleService already attempted backend sync
        // above using the same saleId.
        final localInvoices = await LocalStorageService.loadLocalInvoices();
        localInvoices.removeWhere((invoice) => invoice['invoice_number']?.toString() == invoiceNumber);
        localInvoices.add(newInvoice);
        await LocalStorageService.saveLocalInvoices(localInvoices);
        
        if (kDebugMode) debugPrint('✅ Borrow invoice mirror saved with canonical id $invoiceNumber');
      }

      if (result['success'] == true) {
        _hapticSuccess();
        final commitPrefs = await SharedPreferences.getInstance();
        final committedBillNumber = commitPrefs.getInt('last_bill_number') ?? 0;
        await commitPrefs.setInt('last_bill_number', committedBillNumber + 1);
        // ✅ CRITICAL: Reset loading BEFORE clearing interface so buttons re-enable
        if (mounted) setState(() { isLoading = false; message = ''; });
        _clearSaleInterface();
        final bool cloudConfirmed = result['cloudConfirmed'] == true;
        final int syncCount = (result['syncCount'] is num)
            ? (result['syncCount'] as num).toInt()
            : 0;
        if (mounted) {
          setState(() {
            message = cloudConfirmed
                ? 'Sale synced to cloud successfully ✅'
                : (syncCount > 0
                    ? '$syncCount items queued for sync.'
                    : 'Sale saved locally. Cloud sync pending.');
          });
        }
        
        // SHOW SUCCESS DIALOG WITH REAL BILL PDF
        if (mounted) {
          final String shopName = _shopNameForDynamicQr ?? 'Retail Shop';
          final prefs2 = await SharedPreferences.getInstance();
          final shopPhone2 = prefs2.getString('shop_phone') ?? '';
          final shopAddress2 = prefs2.getString('location') ?? '';
          final gstNumber2 = prefs2.getString('gst_number') ?? '';
          final customerName2 = customerNameController.text.trim();

          // 📄 Generate real PDF bill
          String billFilePath = '';
          try {
            billFilePath = await BillGeneratorService.generateAndSaveBill(
              invoiceId: saleId,
              shopName: shopName,
              shopPhone: shopPhone2,
              shopAddress: shopAddress2,
              gstNumber: gstNumber2,
              customerName: customerName2,
              items: items,
              totalAmount: grandTotal,
              paidAmount: _paidAmount,
              withTax: _withTax,
            );
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Bill PDF generation failed: $e');
          }

          final String qrData = billFilePath.isNotEmpty
              ? 'file://$billFilePath'
              : 'https://wa.me/?text=${Uri.encodeComponent("Bill for $saleId — ₹${grandTotal.toStringAsFixed(2)}")}';

          final String capturedBillPath = billFilePath;
          final String capturedCustomer = customerName2;

          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 60),
                    const SizedBox(height: 12),
                    Text('Sale Successful!', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold)),
                    if (isFirstSaleForThisShop) ...[
                      const SizedBox(height: 10),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.85, end: 1.0),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOutBack,
                        builder: (context, value, child) {
                          return Transform.scale(scale: value, child: child);
                        },
                        child: Column(
                          children: [
                            Icon(Icons.celebration_rounded, color: const Color(0xFF6366F1), size: 34),
                            const SizedBox(height: 6),
                            Text(
                              'Your shop is live!',
                              style: GoogleFonts.poppins(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                color: const Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Great start — keep billing daily.',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Text('Invoice: $saleId', style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey)),
                    if (capturedBillPath.isNotEmpty) ...[  
                      const SizedBox(height: 4),
                      Text('✅ Bill PDF saved to Downloads/RetailMind',
                          style: GoogleFonts.poppins(fontSize: 10, color: const Color(0xFF10B981))),
                    ],
                    const SizedBox(height: 16),

                    // â”€â”€ QR CODE (points to actual PDF file) â”€â”€
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.indigo.withOpacity(0.15)),
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.indigo.withOpacity(0.03),
                      ),
                      child: Column(
                        children: [
                          QrImageView(
                            data: qrData,
                            version: QrVersions.auto,
                            size: 150.0,
                            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF4338CA)),
                            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF4338CA)),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            capturedBillPath.isNotEmpty ? 'SCAN TO OPEN BILL PDF' : 'SCAN FOR DIGITAL BILL',
                            style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1, color: const Color(0xFF4338CA)),
                          ),
                          Text(
                            capturedBillPath.isNotEmpty ? 'Real bill image generated ✍️“' : 'WhatsApp message fallback',
                            style: GoogleFonts.poppins(fontSize: 9, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // â”€â”€ SHARE BILL â”€â”€
                    if (capturedBillPath.isNotEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await BillGeneratorService.shareBill(capturedBillPath, customerName: capturedCustomer);
                          },
                          icon: const Icon(Icons.share_rounded, size: 18),
                          label: Text('SHARE BILL (PDF / WhatsApp)', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),

                    // â”€â”€ PRINT â”€â”€
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          if (capturedBillPath.isNotEmpty) {
                            await BillGeneratorService.printBill(capturedBillPath);
                          } else {
                            // Show message if bill not generated yet
                            if (mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('Please wait for bill generation or use Bluetooth printer'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                            _printBluetooth();
                          }
                        },
                        icon: const Icon(Icons.print_rounded, color: Color(0xFF10B981), size: 18),
                        label: Text('PRINT RECEIPT', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: const Color(0xFF10B981))),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF10B981)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (isBorrow) {
                        Navigator.pushReplacementNamed(context, '/invoices');
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('DONE', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              ],
            ),
          );
        }
        return true;
      } else {
        final errorCode = result['error']?.toString() ?? 'UNKNOWN_ERROR';
        if (errorCode == 'SYNC_NOT_CONFIRMED') {
          if (mounted) {
            setState(() {
              isLoading = false;
              message = '⚠️ Sale saved on this device, but cloud sync is not confirmed yet. Do not create another bill; it will retry automatically.';
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⚠️ Sale saved locally. Server confirmation is pending — do not bill this customer again.'),
                backgroundColor: Color(0xFFD97706),
                duration: Duration(seconds: 6),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return false;
        }
        throw Exception(result['error'] ?? 'Unknown Error');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
          message = 'âŒ Transaction Failed: $e';
        });
      }
      return false;
    }
  }

  Future<void> borrowSale() async {
    if (isLoading) return;

    final rawPhone = customerPhoneController.text.trim();
    final digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
    final normalizedPhone =
        digits.startsWith('91') && digits.length == 12
            ? digits.substring(2)
            : digits;

    if (normalizedPhone.length != 10 ||
        !RegExp(r'^[6-9][0-9]{9}$').hasMatch(normalizedPhone)) {
      if (!mounted) return;
      _borrowWaitingForCustomer = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Customer phone number is required to record the borrow.'),
          backgroundColor: Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _showQuickAddCustomer();
      return;
    }

    if (customerPhoneController.text.trim() != normalizedPhone && mounted) {
      setState(() => customerPhoneController.text = normalizedPhone);
    }

    final totals = calculateTotal() as Map<String, dynamic>;
    final grandTotal = totals['total'] ?? 0.0;

    // 🔵 BORROW LIMIT: Check if customer already has 2 or more unpaid/partial borrows
    final phone = customerPhoneController.text.trim();
    final List<dynamic> history = await LocalStorageService.loadSales();
    
    final pendingBorrows = history.where((s) {
      if (s['customer_phone']?.toString().trim() != phone) return false;
      final status = s['payment_status']?.toString().toUpperCase() ?? 'PAID';
      return status == 'UNPAID' || status == 'PARTIAL';
    }).toList();

    if (pendingBorrows.length >= 2) {
      double totalDueAmount = 0;
      for (var b in pendingBorrows) {
        double total = double.tryParse(b['total']?.toString() ?? '0') ?? 0;
        double paid = double.tryParse(b['paid_amount']?.toString() ?? '0') ?? 0;
        totalDueAmount += (total - paid);
      }
      
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
              const SizedBox(width: 10),
              Text('Borrow Limit Exceeded!', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: const Color(0xFFEF4444))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This customer already has ${pendingBorrows.length} pending borrows.', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.red.withValues(alpha: 0.1))),
                child: Column(
                  children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Outstanding Balance:'), Text('₹${totalDueAmount.toStringAsFixe
Preview truncated for large file