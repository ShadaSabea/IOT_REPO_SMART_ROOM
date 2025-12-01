import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MyReservationsPage extends StatelessWidget {
  const MyReservationsPage({super.key});

  // Format minutes (e.g. 840) to "14:00"
  String _formatTime(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return "$h:$m";
  }

  // Handle QR check-in with 10-minute window
  Future<void> _processQR(BuildContext context, String qr) async {
    try {
      final parts = qr.split(";");
      Map<String, String> data = {};

      // Decode QR payload
      for (var p in parts) {
        final kv = p.split("=");
        if (kv.length == 2) {
          data[kv[0]] = kv[1];
        }
      }

      final roomId = data["roomId"];
      final resId = data["resId"];
      final date = data["date"];
      final startStr = data["start"];

      if (roomId == null || resId == null || date == null || startStr == null) {
        throw Exception("Invalid QR format.");
      }

      // Fetch booking
      final bookingSnap = await FirebaseFirestore.instance
          .collection("bookings")
          .doc(resId)
          .get();

      if (!bookingSnap.exists) {
        throw Exception("Reservation not found.");
      }

      final booking = bookingSnap.data()!;
      final user = FirebaseAuth.instance.currentUser;

      // Validate owner
      if (booking["userId"] != user!.uid) {
        throw Exception("This reservation does NOT belong to you.");
      }

      // Read system time
      final systemSnap = await FirebaseFirestore.instance
          .collection("system")
          .doc("time")
          .get();

      final systemDate = systemSnap["date"];
      final systemTime = systemSnap["currentTime"]; // e.g. "14:11"

      if (systemDate != date) {
        throw Exception("Wrong day. Cannot check in.");
      }

      // Convert system time to minutes
      final hhmm = systemTime.split(":");
      final nowMin = int.parse(hhmm[0]) * 60 + int.parse(hhmm[1]);

      // Use booking startTime if present, otherwise QR start
      final int startMin =
          (booking["startTime"] as int?) ?? int.parse(startStr);

      // ✅ NEW: get windowStart from booking (computed when booking was created)
      // If windowStartMinutes is missing (old bookings), fall back to startMin.
      final int windowStart =
          (booking["windowStartMinutes"] as int?) ?? startMin;

      // ✅ Check-in window: from windowStart until 10 minutes after windowStart
      const int checkInWindowMinutes = 10;

      if (nowMin < windowStart) {
        throw Exception("Too early for check-in.");
      }

      if (nowMin > windowStart + checkInWindowMinutes) {
        // ❌ Too late → mark reservation as expired and free the room
        await bookingSnap.reference.update({
          "status": "expired",
          "isCheckedIn": false,
        });

        await FirebaseFirestore.instance
            .collection("rooms")
            .doc(roomId)
            .update({
          "status": "free",
          "currentReservationId": FieldValue.delete(),
        });

        throw Exception(
          "Reservation expired (no check-in within 10 minutes). Room is now free.",
        );
      }

      // ✅ Still within the 10-minute window → check-in succeeds
      await bookingSnap.reference.update({
        "status": "active",
        "isCheckedIn": true,
      });

      await FirebaseFirestore.instance
          .collection("rooms")
          .doc(roomId)
          .update({
        "status": "occupied",
        "currentReservationId": resId,
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Check-in successful!")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  // 🔁 Auto-expire a booking based on /system/time when user opens this page
  Future<void> _autoExpireBooking(DocumentSnapshot bookingDoc) async {
    final data = bookingDoc.data() as Map<String, dynamic>;

    final String? date = data['date'] as String?;
    final int? startMinutes = data['startTime'] as int?;
    final String status = (data['status'] ?? 'upcoming').toString();
    final bool isCheckedIn = data['isCheckedIn'] == true;

    // Only care about upcoming, not-yet-checked-in reservations
    if (date == null || startMinutes == null) return;
    if (status != 'upcoming' || isCheckedIn) return;

    // ✅ NEW: windowStart from booking; fallback to slot start
    final int windowStart =
        (data['windowStartMinutes'] as int?) ?? startMinutes;

    // Read system time
    final systemSnap = await FirebaseFirestore.instance
        .collection('system')
        .doc('time')
        .get();

    final systemDate = systemSnap['date'];
    final String? systemTime = systemSnap['currentTime'];
    if (systemTime == null) return;

    // Only expire if same date
    if (systemDate != date) return;

    final parts = systemTime.split(':');
    if (parts.length != 2) return;

    final nowMinutes =
        int.parse(parts[0]) * 60 + int.parse(parts[1]);

    const int checkInWindowMinutes = 10;

    if (nowMinutes > windowStart + checkInWindowMinutes) {
      // 🔴 Expire booking
      await bookingDoc.reference.update({
        'status': 'expired',
        'isCheckedIn': false,
      });

      // Free the room if it points to this reservation
      final String? roomId = data['roomId'] as String?;
      if (roomId != null) {
        final roomSnap = await FirebaseFirestore.instance
            .collection('rooms')
            .doc(roomId)
            .get();

        if (roomSnap.exists) {
          final roomData = roomSnap.data() as Map<String, dynamic>;
          final String? currentRes =
              roomData['currentReservationId'] as String?;
          if (currentRes == bookingDoc.id) {
            await roomSnap.reference.update({
              'status': 'free',
              'currentReservationId': FieldValue.delete(),
            });
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(child: Text("Please log in.")),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("My Reservations"),
        centerTitle: true,
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // REAL QR scanner button
          FloatingActionButton(
            heroTag: "qr",
            backgroundColor: Colors.deepPurple,
            onPressed: () async {
              final qrData = await Navigator.pushNamed(context, "/qrscanner");
              if (qrData == null) return;
              await _processQR(context, qrData.toString());
            },
            child: const Icon(Icons.qr_code_scanner,
                size: 28, color: Colors.white),
          ),
          const SizedBox(height: 12),
          // TEST button (fake QR)
          FloatingActionButton(
            heroTag: "test",
            backgroundColor: Colors.orange,
            onPressed: () async {
              await _processQR(
                context,
                "roomId=7vrgmE2jIOoDl3UO5fSI;resId=csUdBuYt7kPwNVMv86wy;date=2025-11-25;start=840",
              );
            },
            child: const Icon(Icons.bug_report,
                size: 28, color: Colors.white),
          ),
        ],
      ),

      // 1) First, load all rooms to map roomId -> roomName
      body: FutureBuilder<QuerySnapshot>(
        future: FirebaseFirestore.instance.collection('rooms').get(),
        builder: (context, roomsSnap) {
          if (roomsSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          // Build map of roomId -> roomName
          final Map<String, String> roomNames = {};
          if (roomsSnap.hasData) {
            for (var doc in roomsSnap.data!.docs) {
              final data = doc.data() as Map<String, dynamic>;
              final status = data['status'] ?? 'upcoming';
              roomNames[doc.id] =
                  (data['name'] ?? 'Unknown room').toString();
            }
          }

          // 2) Now listen to this user's bookings
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("bookings")
                .where("userId", isEqualTo: user.uid)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (!snapshot.hasData) {
                return const Center(child: Text("No reservations."));
              }

              final docs = snapshot.data!.docs;

              // 🔁 Auto-expire outdated bookings based on /system/time
              for (final d in docs) {
                _autoExpireBooking(d);
              }

              if (docs.isEmpty) {
                return const Center(
                    child: Text("You have no reservations."));
              }

              // Today (date only)
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);

              // Filter to today & future dates, hide expired
              final filtered = docs.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final status =
                    (data["status"] ?? 'upcoming').toString();
                if (status == 'expired') return false;

                final dateStr = data["date"] as String?;
                if (dateStr == null) return false;
                try {
                  final d = DateTime.parse(dateStr);
                  final onlyDate =
                      DateTime(d.year, d.month, d.day);
                  return !onlyDate.isBefore(today); // keep >= today
                } catch (_) {
                  return false;
                }
              }).toList();

              // Sort by (date, startTime)
              filtered.sort((a, b) {
                final aData =
                    a.data() as Map<String, dynamic>;
                final bData =
                    b.data() as Map<String, dynamic>;

                final ad = DateTime.parse(aData["date"]);
                final bd = DateTime.parse(bData["date"]);
                final cmp = ad.compareTo(bd);
                if (cmp != 0) return cmp;

                final aStart =
                    (aData["startTime"] ?? 0) as int;
                final bStart =
                    (bData["startTime"] ?? 0) as int;
                return aStart.compareTo(bStart);
              });

              if (filtered.isEmpty) {
                return const Center(
                    child: Text("You have no upcoming reservations."));
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final doc = filtered[index];
                  final data =
                      doc.data() as Map<String, dynamic>;

                  final roomId =
                      data["roomId"] as String? ?? "";
                  final roomName =
                      roomNames[roomId] ?? "Unknown room";

                  final date = data["date"] as String? ?? "";
                  final pin =
                      data["pin"]?.toString() ?? "----";
                  final startMinutes =
                      (data["startTime"] ?? 0) as int;
                  final endMinutes =
                      (data["endTime"] ?? 0) as int;
                  final status =
                      (data["status"] ?? 'upcoming').toString();

                  final timeRange =
                      "${_formatTime(startMinutes)} - ${_formatTime(endMinutes)}";

                  return Container(
                    margin:
                        const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.shade50,
                      borderRadius:
                          BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        // ⭐ TITLE = ROOM NAME ONLY
                        Text(
                          roomName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text("Date: $date"),
                        Text("Time: $timeRange"),
                        Text("Status: $status"),
                        const SizedBox(height: 6),
                        Text(
                          "PIN: $pin",
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
