import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// import your pages
import 'login_page.dart';
import 'signup_page.dart';
import 'home_page.dart';
import 'my_reservations_page.dart';   // NEW
import 'main_screen.dart';            // NEW
import 'qrscanner.dart';              // NEW

/// **************************************************************
///   HELPER: RECALCULATE ROOMS ACCORDING TO VIRTUAL DATE/TIME
/// **************************************************************
Future<void> _recalculateRoomsForVirtualTime(
  String date,
  String time,
) async {
  // convert HH:mm → minutes
  final parts = time.split(":");
  if (parts.length != 2) return;

  final int nowMin = int.parse(parts[0]) * 60 + int.parse(parts[1]);

  // get all rooms
  final roomsSnap =
      await FirebaseFirestore.instance.collection('rooms').get();

  for (var roomDoc in roomsSnap.docs) {
    final roomId = roomDoc.id;

    // get bookings for this room on this date
    final bookingsSnap = await FirebaseFirestore.instance
        .collection('bookings')
        .where("roomId", isEqualTo: roomId)
        .where("date", isEqualTo: date)
        .get();

    String? activeId;
    String roomStatus = "free"; // will follow booking status if we find one

    // pick ONLY booking that is active RIGHT NOW
    for (var b in bookingsSnap.docs) {
      final data = b.data();

      final int start = data['startTime'] as int;
      final int end = data['endTime'] as int;
      String bookingStatus =
          (data['status'] ?? 'upcoming').toString();

      // windowStartMinutes is used for the 10-minute QR window.
      // If it doesn't exist, fall back to start time.
      final int windowStart =
          (data['windowStartMinutes'] ?? start) as int;

// 1) Decide if this booking should be expired now
final bool qrWindowPassed = nowMin > windowStart + 10;
final bool slotEnded = nowMin >= end;

bool shouldExpire = false;

if (bookingStatus == "upcoming") {
  // User did NOT check in yet
  // → expire after 10min OR if the slot ended
  shouldExpire = qrWindowPassed || slotEnded;

} else if (bookingStatus == "checked-in") {
  // User ALREADY checked in
  // → DO NOT expire after 10 minutes
  // → Only expire if the slot ended
  shouldExpire = slotEnded;

} else {
  // expired / cancelled / anything else → do not expire again
  shouldExpire = false;
}

if (shouldExpire && bookingStatus != "expired") {
  await b.reference.update({
    "status": "expired",
    "isCheckedIn": false,
  });
  bookingStatus = "expired";
}


      // 2) Only consider non-expired bookings whose time window includes now
      final bool insideSlot = nowMin >= start && nowMin < end;
      if (!insideSlot) continue;
      if (bookingStatus == "expired") continue;

      // This booking is relevant "right now"
      activeId = b.id;

      // Room status according to booking status
      if (bookingStatus == "checked-in") {
        roomStatus = "occupied";
      } else if (bookingStatus == "upcoming") {
        roomStatus = "upcoming";
      } else {
        roomStatus = "free";
      }

      // We found the booking for this time; no need to check others
      break;
    }

    // update the room with the correct ID + status
    if (activeId == null) {
      await roomDoc.reference.update({
        "currentReservationId": null,
        "status": "free",
      });
    } else {
      await roomDoc.reference.update({
        "currentReservationId": activeId,
        "status": roomStatus, // derived from booking status
      });
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    // If you have firebase_options.dart uncomment:
    // options: DefaultFirebaseOptions.currentPlatform,
  );

  // LISTENER 1: AUTO UPDATE ROOMS WHEN VIRTUAL TIME CHANGES
  FirebaseFirestore.instance
      .collection('system')
      .doc('time')
      .snapshots()
      .listen((systemSnap) async {
    if (!systemSnap.exists) return;

    final date = systemSnap.data()?['date'];
    final time = systemSnap.data()?['currentTime'];

    if (date == null || time == null) return;

    await _recalculateRoomsForVirtualTime(date, time);
  });

  // LISTENER 2: AUTO UPDATE ROOMS WHEN BOOKINGS CHANGE
  FirebaseFirestore.instance
      .collection('bookings')
      .snapshots()
      .listen((_) async {
    // Get current virtual time from system/time
    final systemSnap = await FirebaseFirestore.instance
        .collection('system')
        .doc('time')
        .get();

    if (!systemSnap.exists) return;

    final date = systemSnap.data()?['date'];
    final time = systemSnap.data()?['currentTime'];

    if (date == null || time == null) return;

    await _recalculateRoomsForVirtualTime(date, time);
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Room',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),

      // Routes
      initialRoute: '/',
      routes: {
        '/': (context) => const WelcomeScreen(),
        '/login': (context) => const LoginPage(),
        '/signup': (context) => const SignUpPage(),

        // OLD home replaced by MainScreen
        '/home': (context) => const MainScreen(),
        '/qrscanner': (context) => const QRScannerPage(), // NEW
      },
    );
  }
}

/// **************************************************************
///                WELCOME SCREEN (FIRST PAGE)
/// **************************************************************
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Smart Room',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Reserve rooms easily and manage your bookings.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),

              // LOGIN BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pushNamed(context, '/login');
                  },
                  child: const Text('Log In'),
                ),
              ),
              const SizedBox(height: 12),

              // SIGNUP BUTTON
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pushNamed(context, '/signup');
                  },
                  child: const Text('Sign Up'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
