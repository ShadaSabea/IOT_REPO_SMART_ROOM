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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    // If you have firebase_options.dart uncomment:
    // options: DefaultFirebaseOptions.currentPlatform,
  );

  // AUTO UPDATE ROOMS BASED ON SYSTEM TIME
FirebaseFirestore.instance
    .collection('system')
    .doc('time')
    .snapshots()
    .listen((systemSnap) async {

  if (!systemSnap.exists) return;

  final date = systemSnap.data()?['date'];
  final time = systemSnap.data()?['currentTime'];

  if (date == null || time == null) return;

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

    // pick ONLY booking that is active RIGHT NOW
    for (var b in bookingsSnap.docs) {
      final data = b.data();

      final int start = data['startTime'];
      final int end = data['endTime'];
      final String status = data['status'];

      final bool isActive =
          status != "expired" &&
          nowMin >= start &&
          nowMin < end;

      if (isActive) {
        activeId = b.id;
        break;
      }
    }

    // update the room with the correct ID
    if (activeId == null) {
      await roomDoc.reference.update({
        "currentReservationId": null,
        "status": "free",
      });
    } else {
      await roomDoc.reference.update({
        "currentReservationId": activeId,
        "status": "occupied",
      });
    }
  }
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