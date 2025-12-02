import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MyReservationsPage extends StatelessWidget {
  const MyReservationsPage({super.key});

  String _formatTime(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return "$h:$m";
  }

  Future<void> _processQR(BuildContext context, String qr) async {
    try {
      final parts = qr.split(";");
      Map<String, String> data = {};

      for (var p in parts) {
        final kv = p.split("=");
        if (kv.length == 2) data[kv[0]] = kv[1];
      }

      final roomId = data["roomId"];
      final resId = data["resId"];
      final date = data["date"];
      final startStr = data["start"];

      if (roomId == null || resId == null || date == null || startStr == null) {
        throw Exception("Invalid QR format.");
      }

      final bookingSnap = await FirebaseFirestore.instance
          .collection("bookings")
          .doc(resId)
          .get();

      if (!bookingSnap.exists) throw Exception("Reservation not found.");

      final booking = bookingSnap.data()!;
      final user = FirebaseAuth.instance.currentUser;

      if (booking["userId"] != user!.uid) {
        throw Exception("This reservation does NOT belong to you.");
      }

      final systemSnap = await FirebaseFirestore.instance
          .collection("system")
          .doc("time")
          .get();

      final systemDate = systemSnap["date"];
      final systemTime = systemSnap["currentTime"];

      if (systemDate != date) throw Exception("Wrong day.");

      final hhmm = systemTime.split(":");
      final nowMin = int.parse(hhmm[0]) * 60 + int.parse(hhmm[1]);

      final int startMin =
          (booking["startTime"] as int?) ?? int.parse(startStr);

      final int windowStart =
          (booking["windowStartMinutes"] as int?) ?? startMin;

      const int checkInWindowMinutes = 10;

      if (nowMin < windowStart) {
        throw Exception("Too early for check-in.");
      }

      if (nowMin > windowStart + checkInWindowMinutes) {
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

        throw Exception("Reservation expired.");
      }

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

      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Check-in successful!")));

    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  Future<void> _autoExpireBooking(DocumentSnapshot bookingDoc) async {
    final data = bookingDoc.data() as Map<String, dynamic>;

    final String? date = data['date'] as String?;
    final int? startMinutes = data['startTime'] as int?;
    final String status = (data['status'] ?? 'upcoming').toString();
    final bool isCheckedIn = data['isCheckedIn'] == true;

    if (date == null || startMinutes == null) return;
    if (status != 'upcoming' || isCheckedIn) return;

    final int windowStart =
        (data['windowStartMinutes'] as int?) ?? startMinutes;

    final systemSnap = await FirebaseFirestore.instance
        .collection('system')
        .doc('time')
        .get();

    final systemDate = systemSnap['date'];
    final String? systemTime = systemSnap['currentTime'];
    if (systemTime == null) return;
    if (systemDate != date) return;

    final parts = systemTime.split(':');
    if (parts.length != 2) return;

    final nowMinutes =
        int.parse(parts[0]) * 60 + int.parse(parts[1]);

    const int checkInWindowMinutes = 10;

    if (nowMinutes > windowStart + checkInWindowMinutes) {
      await bookingDoc.reference.update({
        'status': 'expired',
        'isCheckedIn': false,
      });

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

      // 🔵 REAL-TIME VIRTUAL TIME (REQUIRED FOR LIVE EXPIRY)
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection("system")
            .doc("time")
            .snapshots(),
        builder: (context, timeSnap) {

          // once time arrives, rebuild normally
          return FutureBuilder<QuerySnapshot>(
            future: FirebaseFirestore.instance.collection('rooms').get(),
            builder: (context, roomsSnap) {

              if (roomsSnap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final Map<String, String> roomNames = {};
              if (roomsSnap.hasData) {
                for (var doc in roomsSnap.data!.docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  roomNames[doc.id] =
                      (data['name'] ?? 'Unknown room').toString();
                }
              }

              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("bookings")
                    .where("userId", isEqualTo: user.uid)
                    .snapshots(),
                builder: (context, snapshot) {

                  if (!snapshot.hasData) {
                    return const Center(child: Text("No reservations."));
                  }

                  final docs = snapshot.data!.docs;

                  // AUTO-EXPIRE LIVE
                  for (final d in docs) {
                    _autoExpireBooking(d);
                  }

                  if (docs.isEmpty) {
                    return const Center(
                      child: Text("You have no reservations."),
                    );
                  }

                  final now = DateTime.now();
                  final today =
                      DateTime(now.year, now.month, now.day);

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
                      return !onlyDate.isBefore(today);
                    } catch (_) {
                      return false;
                    }
                  }).toList();

                  filtered.sort((a, b) {
                    final aData = a.data() as Map<String, dynamic>;
                    final bData = b.data() as Map<String, dynamic>;

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
                      child: Text("You have no upcoming reservations."),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final doc = filtered[index];
                      final data = doc.data() as Map<String, dynamic>;

                      final roomId = data["roomId"] ?? "";
                      final roomName = roomNames[roomId] ?? "Unknown room";

                      final date = data["date"] ?? "";
                      final pin = data["pin"]?.toString() ?? "----";
                      final startMinutes = (data["startTime"] ?? 0) as int;
                      final endMinutes = (data["endTime"] ?? 0) as int;
                      final status =
                          (data["status"] ?? 'upcoming').toString();

                      final timeRange =
                          "${_formatTime(startMinutes)} - ${_formatTime(endMinutes)}";

                      return Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.shade50,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
          );
        },
      ),
    );
  }
}
