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

    // Simple 4-digit PIN
    String pin =
        (1000 + (DateTime.now().millisecondsSinceEpoch % 9000)).toString();

    await FirebaseFirestore.instance.collection("bookings").add({
      "roomId": widget.roomId,
      "userId": user.uid,
      "date": date,
      "slot": slot,
      "startTime": startMinutes,
      "endTime": endMinutes,
      "pin": pin,
      "qrData": "", // placeholder for later
      "createdAt": FieldValue.serverTimestamp(),
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Booking successful! Your PIN: $pin")),
    );
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
      body: StreamBuilder<QuerySnapshot>(
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
            for (var doc in snapshot.data!.docs) {
              reservedSlots.add(doc["slot"] as int);
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
     ),
);
}
}