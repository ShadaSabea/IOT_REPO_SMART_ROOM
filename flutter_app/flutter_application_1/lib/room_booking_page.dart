import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class RoomBookingPage extends StatefulWidget {
  final String roomId;
  final String roomName;

  const RoomBookingPage({
    super.key,
    required this.roomId,
    required this.roomName,
  });

  @override
  State<RoomBookingPage> createState() => _RoomBookingPageState();
}

class _RoomBookingPageState extends State<RoomBookingPage> {
  DateTime _selectedDate = DateTime.now();

  String _formatDate(DateTime d) {
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
  }

  // 6 fixed 2-hour slots
  final List<Map<String, dynamic>> _slots = const [
    {"slot": 1, "start": "08:00", "end": "10:00"},
    {"slot": 2, "start": "10:00", "end": "12:00"},
    {"slot": 3, "start": "12:00", "end": "14:00"},
    {"slot": 4, "start": "14:00", "end": "16:00"},
    {"slot": 5, "start": "16:00", "end": "18:00"},
    {"slot": 6, "start": "18:00", "end": "20:00"},
  ];

Future<void> _createBooking({
  required int slot,
  required String start,
  required String end,
  required String date,
}) async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Please log in first")),
    );
    return;
  }

  // Time → minutes from midnight
  final startHour = int.parse(start.split(":")[0]);
  final startMin = int.parse(start.split(":")[1]);
  final endHour = int.parse(end.split(":")[0]);
  final endMin = int.parse(end.split(":")[1]);

  final int startMinutes = startHour * 60 + startMin;
  final int endMinutes = endHour * 60 + endMin;

  // 🔹 NEW: compute windowStartMinutes based on /system/time
  int windowStartMinutes = startMinutes;
  try {
    final systemSnap = await FirebaseFirestore.instance
        .collection('system')
        .doc('time')
        .get();

    final data = systemSnap.data() as Map<String, dynamic>?;
    final String? systemDate = data?['date'] as String?;
    final String? systemTime = data?['currentTime'] as String?;

    if (systemDate == date && systemTime != null) {
      final parts = systemTime.split(':');
      if (parts.length == 2) {
        final sysMinutes =
            int.parse(parts[0]) * 60 + int.parse(parts[1]);

        // If user books after slot started → give them 10 minutes from NOW
        if (sysMinutes > startMinutes) {
          windowStartMinutes = sysMinutes;
        }
      }
    } else {
      // booking for future date → window starts at slot start
      windowStartMinutes = startMinutes;
    }
  } catch (_) {
    // if anything fails, fall back to slot start
    windowStartMinutes = startMinutes;
  }

  // Simple 4-digit PIN
  String pin =
      (1000 + (DateTime.now().millisecondsSinceEpoch % 9000)).toString();

  // ⿡ Create booking FIRST (temporary qrData)
  final docRef =
      await FirebaseFirestore.instance.collection("bookings").add({
    "roomId": widget.roomId,
    "userId": user.uid,
    "date": date,
    "slot": slot,
    "startTime": startMinutes,
    "endTime": endMinutes,
    "pin": pin,

    // ⭐ NEW FIELD:
    "windowStartMinutes": windowStartMinutes,

    // ⭐ REQUIRED FOR OUR PROJECT:
    "qrData": "", // will update after we get the ID
    "status": "upcoming",
    "isCheckedIn": false,

    "createdAt": FieldValue.serverTimestamp(), // keep just for info
  });

  // ⿢ Build the QR payload NOW (room + resId + date + startTime)
  String qrPayload =
      "roomId=${widget.roomId};resId=${docRef.id};date=$date;start=$startMinutes";

  // ⿣ Update booking with qrData
  await docRef.update({"qrData": qrPayload});

  // ⿤ Update ROOM status so ESP32 knows there is an upcoming reservation
  await FirebaseFirestore.instance
      .collection("rooms")
      .doc(widget.roomId)
      .update({
    "status": "upcoming",
    "currentReservationId": docRef.id,
  });

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text("Booking successful! Your PIN: $pin")),
  );
}


  /// 🔁 Auto-expire a single booking of THIS room based on /system/time,
  /// using dynamic windowStart = max(startTime, createdAt).
Future<void> _autoExpireBookingForDoc(DocumentSnapshot bookingDoc) async {
  final data = bookingDoc.data() as Map<String, dynamic>;

  final String? date = data['date'] as String?;
  final int? startMinutes = data['startTime'] as int?;
  final String status = (data['status'] ?? 'upcoming').toString();
  final bool isCheckedIn = data['isCheckedIn'] == true;

  // Only care about upcoming, not-yet-checked-in reservations
  if (date == null || startMinutes == null) return;
  if (status != 'upcoming' || isCheckedIn) return;

  // 🚨 NEW: if createdAt not ready yet, skip auto-expire
  final createdAtTs = data['createdAt'];
  if (createdAtTs == null || createdAtTs is! Timestamp) {
    return;
  }

  // Read system time
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

  // 🕒 Dynamic windowStart = max(startTime, createdAt)
  int windowStart = startMinutes;

  final createdAt = createdAtTs.toDate();
  final bookingDate = DateTime.parse(date);
  final sameDay = createdAt.year == bookingDate.year &&
      createdAt.month == bookingDate.month &&
      createdAt.day == bookingDate.day;

  if (sameDay) {
    final createdMinutes = createdAt.hour * 60 + createdAt.minute;
    if (createdMinutes > startMinutes) {
      windowStart = createdMinutes;
    }
  }

  const int checkInWindowMinutes = 10;

  if (nowMinutes > windowStart + checkInWindowMinutes) {
    // 🔴 Expire booking
    await bookingDoc.reference.update({
      'status': 'expired',
      'isCheckedIn': false,
    });

    // Free the room if it points to this reservation
    final roomSnap = await FirebaseFirestore.instance
        .collection('rooms')
        .doc(widget.roomId)
        .get();

    if (roomSnap.exists) {
      final roomData =
          roomSnap.data() as Map<String, dynamic>;
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


  @override
  Widget build(BuildContext context) {
    final dateString = _formatDate(_selectedDate);

    return Scaffold(
      appBar: AppBar(
        title: Text("${widget.roomName} – $dateString"),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _selectedDate,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 60)),
              );
              if (picked != null) {
                setState(() => _selectedDate = picked);
              }
            },
          )
        ],
      ),

      // 🔁 Listen to /system/time so any manual time change triggers a rebuild
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('system')
            .doc('time')
            .snapshots(),
        builder: (context, timeSnap) {
          // Even if timeSnap is loading, we still show bookings; time is only for expiry.
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("bookings")
                .where("roomId", isEqualTo: widget.roomId)
                .where("date", isEqualTo: dateString)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final reservedSlots = <int>{};
              if (snapshot.hasData) {
                final docs = snapshot.data!.docs;

                // 🔁 Auto-expire each booking of this room based on /system/time
                for (final d in docs) {
                  _autoExpireBookingForDoc(d);
                }

                for (var doc in docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  final status = (data["status"] ?? "upcoming").toString();

                  // ✅ Do NOT block the slot if this booking already expired
                  if (status == "expired") continue;

                  reservedSlots.add(data["slot"] as int);
                }
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _slots.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final slot = _slots[index];
                  final int slotNumber = slot["slot"];
                  final bool isReserved = reservedSlots.contains(slotNumber);

                  return GestureDetector(
                    onTap: isReserved
                        ? null
                        : () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text("Confirm Booking"),
                                content: Text(
                                    "Reserve ${slot["start"]} - ${slot["end"]}?"),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text("Cancel"),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text("Confirm"),
                                  ),
                                ],
                              ),
                            );

                            if (confirm == true) {
                              await _createBooking(
                                slot: slotNumber,
                                start: slot["start"],
                                end: slot["end"],
                                date: dateString,
                              );
                            }
                          },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isReserved
                            ? Colors.red.shade100
                            : Colors.green.shade100,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isReserved ? Colors.red : Colors.green,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isReserved ? Icons.lock : Icons.lock_open,
                            color: isReserved ? Colors.red : Colors.green,
                            size: 28,
                          ),
                          const SizedBox(width: 16),
                          Text(
                            "${slot["start"]} - ${slot["end"]}",
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            isReserved ? "Reserved" : "Available",
                            style: TextStyle(
                              fontSize: 18,
                              color: isReserved ? Colors.red : Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
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
