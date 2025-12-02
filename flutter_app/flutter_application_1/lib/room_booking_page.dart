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

  final List<Map<String, dynamic>> _slots = const [
    {"slot": 1, "start": "08:00", "end": "10:00"},
    {"slot": 2, "start": "10:00", "end": "12:00"},
    {"slot": 3, "start": "12:00", "end": "14:00"},
    {"slot": 4, "start": "14:00", "end": "16:00"},
    {"slot": 5, "start": "16:00", "end": "18:00"},
    {"slot": 6, "start": "18:00", "end": "20:00"},
  ];

  int _hhmmToMinutes(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  // --------------------
  // YOUR ORIGINAL _createBooking() (unchanged)
  // --------------------
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
    // 🔹 NEW: get email prefix (before '@') to save as "name"
  final String? email = user.email;
  String nameBeforeAt = "";
  if (email != null && email.contains("@")) {
    nameBeforeAt = email.split("@")[0];
  }

    final startMinutes = _hhmmToMinutes(start);
    final endMinutes = _hhmmToMinutes(end);

    int windowStartMinutes = startMinutes;
    try {
      final systemSnap = await FirebaseFirestore.instance
          .collection('system')
          .doc('time')
          .get();

      final data = systemSnap.data() as Map<String, dynamic>?;
      final String? systemDate = data?['date'];
      final String? systemTime = data?['currentTime'];

      if (systemDate == date && systemTime != null) {
        final sysMin = _hhmmToMinutes(systemTime);
        if (sysMin > startMinutes) windowStartMinutes = sysMin;
      }
    } catch (_) {}

    final pin =
        (1000 + (DateTime.now().millisecondsSinceEpoch % 9000)).toString();

    final docRef =
        await FirebaseFirestore.instance.collection("bookings").add({
      "roomId": widget.roomId,
      "userId": user.uid,
      "userName": nameBeforeAt,
      "date": date,
      "slot": slot,
      "startTime": startMinutes,
      "endTime": endMinutes,
      "pin": pin,
      "windowStartMinutes": windowStartMinutes,
      "qrData": "",
      "status": "upcoming",
      "isCheckedIn": false,
      "createdAt": FieldValue.serverTimestamp(),
    });

    String qrPayload =
        "roomId=${widget.roomId};resId=${docRef.id};date=$date;start=$startMinutes";

    await docRef.update({"qrData": qrPayload});

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

  // --------------------
  // YOUR ORIGINAL Auto-Expire (unchanged)
  // --------------------
  Future<void> _autoExpireBookingForDoc(DocumentSnapshot bookingDoc) async {
    final data = bookingDoc.data() as Map<String, dynamic>;

    final String? date = data['date'];
    final int? startMinutes = data['startTime'];
    final String status = (data['status'] ?? 'upcoming');
    final bool isCheckedIn = data['isCheckedIn'] == true;

    if (date == null || startMinutes == null) return;
    if (status != 'upcoming' || isCheckedIn) return;

    final createdAtTs = data['createdAt'];
    if (createdAtTs == null || createdAtTs is! Timestamp) return;

    final systemSnap = await FirebaseFirestore.instance
        .collection('system')
        .doc('time')
        .get();

    final systemDate = systemSnap['date'];
    final String? systemTime = systemSnap['currentTime'];
    if (systemTime == null || systemDate != date) return;

    final parts = systemTime.split(':');
    final nowMinutes =
        int.parse(parts[0]) * 60 + int.parse(parts[1]);

    int windowStart = startMinutes;

    final createdAt = createdAtTs.toDate();
    final bookingDate = DateTime.parse(date);
    final sameDay =
        createdAt.year == bookingDate.year &&
            createdAt.month == bookingDate.month &&
            createdAt.day == bookingDate.day;

    if (sameDay) {
      final createdMinutes =
          createdAt.hour * 60 + createdAt.minute;
      if (createdMinutes > startMinutes)
        windowStart = createdMinutes;
    }

    if (nowMinutes > windowStart + 10) {
      await bookingDoc.reference.update({
        'status': 'expired',
        'isCheckedIn': false,
      });

      final roomSnap = await FirebaseFirestore.instance
          .collection('rooms')
          .doc(widget.roomId)
          .get();

      if (roomSnap.exists) {
        final roomData = roomSnap.data() as Map<String, dynamic>;
        if (roomData['currentReservationId'] == bookingDoc.id) {
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

      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('system')
            .doc('time')
            .snapshots(),
        builder: (context, timeSnap) {
          // 🔵 NEW: GET REAL-TIME VIRTUAL TIME
          String? systemDate;
          int? systemMinutes;

          if (timeSnap.hasData && timeSnap.data?.data() != null) {
            final t = timeSnap.data!.data() as Map<String, dynamic>;
            systemDate = t['date'];
            final String? systemTime = t['currentTime'];
            if (systemTime != null) {
              systemMinutes = _hhmmToMinutes(systemTime);
            }
          }

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
                for (final d in docs) _autoExpireBookingForDoc(d);

                for (var doc in docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  if (data["status"] != "expired") {
                    reservedSlots.add(data["slot"]);
                  }
                }
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _slots.length-1,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final slot = _slots[index];
                  final slotNumber = slot["slot"];
                  final slotEnd = _hhmmToMinutes(slot["end"]);

                  final bool isReserved = reservedSlots.contains(slotNumber);

                  // 🔵 NEW: PAST SLOT COMPUTATION
                  bool isPast = false;
                  if (systemDate != null && systemMinutes != null) {
                    if (dateString.compareTo(systemDate) < 0) {
                      isPast = true;
                    } else if (dateString == systemDate) {
                      if (slotEnd <= systemMinutes) isPast = true;
                    }
                  }

                  // final lock:
                  final bool locked = isReserved || isPast;

                  return GestureDetector(
                    onTap: locked
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
                        color: locked
                            ? (isReserved
                                ? Colors.red.shade100
                                : Colors.grey.shade300)
                            : Colors.green.shade100,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: locked
                              ? (isReserved ? Colors.red : Colors.grey)
                              : Colors.green,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            locked
                                ? (isReserved
                                    ? Icons.lock
                                    : Icons.lock_clock)
                                : Icons.lock_open,
                            color: locked
                                ? (isReserved ? Colors.red : Colors.grey)
                                : Colors.green,
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
                            isReserved
                                ? "Reserved"
                                : (isPast ? "Past" : "Available"),
                            style: TextStyle(
                              fontSize: 18,
                              color: locked
                                  ? (isReserved ? Colors.red : Colors.grey)
                                  : Colors.green,
                              fontWeight: FontWeight.bold),
                          )
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
