import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'room_booking_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Rooms"),
        centerTitle: true,
      ),

      // 🔁 Listen to /system/time so changing time in Firestore
      //    will also rebuild this page and re-run _checkAndExpireRoom.
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('system')
            .doc('time')
            .snapshots(),
        builder: (context, timeSnap) {
          // Even if system time is loading, we still show rooms.
          return StreamBuilder<QuerySnapshot>(
            stream:
                FirebaseFirestore.instance.collection('rooms').snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Center(child: Text("No rooms found"));
              }

              final rooms = snapshot.data!.docs;

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: rooms.length,
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  final roomId = room.id;
                  final name = room['name'];
                  final capacity = room['capacity'];
                  final location = room['location'];
                  final status = room['status'] ?? 'free';
                  
                  // 🔁 Auto-expire room's reservation if no check-in within 10 minutes
                  _checkAndExpireRoom(room);

                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => RoomBookingPage(
                            roomId: roomId,
                            roomName: name,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          colors: [
                            Colors.deepPurple.shade50,
                            Colors.deepPurple.shade100.withOpacity(0.6),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.deepPurple.withOpacity(0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            // Room icon
                            Container(
                              width: 55,
                              height: 55,
                              decoration: BoxDecoration(
                                color: Colors.deepPurple.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.meeting_room,
                                size: 32,
                                color: Colors.deepPurple,
                              ),
                            ),
                            const SizedBox(width: 16),

                            // Room info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "Capacity: $capacity",
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  Text(
                                    "Location: $location",
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  Text(
                                    "Status: $status",
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const Icon(Icons.arrow_forward_ios, size: 18),
                          ],
                        ),
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

Future<void> _checkAndExpireRoom(DocumentSnapshot roomDoc) async {
  final data = roomDoc.data() as Map<String, dynamic>;

  final String status = (data['status'] ?? 'free').toString();
  final String? currentReservationId =
      data['currentReservationId'] as String?;

  // If room already free or no reservation linked, nothing to do
  if (status == 'free' || currentReservationId == null) {
    return;
  }

  // Load the linked booking
  final bookingSnap = await FirebaseFirestore.instance
      .collection('bookings')
      .doc(currentReservationId)
      .get();

  // If no such booking, free the room
  if (!bookingSnap.exists) {
    await roomDoc.reference.update({
      'status': 'free',
      'currentReservationId': FieldValue.delete(),
    });
    return;
  }

  final booking = bookingSnap.data() as Map<String, dynamic>;
  final String bookingStatus =
      (booking['status'] ?? 'upcoming').toString();
  final bool isCheckedIn = booking['isCheckedIn'] == true;

  // If booking already active, expired, or checked-in, do nothing
  if (bookingStatus == 'active' ||
      bookingStatus == 'expired' ||
      isCheckedIn) {
    return;
  }

  final String? date = booking['date'] as String?;
  final int? startMinutes = booking['startTime'] as int?;
  if (date == null || startMinutes == null) {
    return;
  }

  // ✅ NEW: use windowStartMinutes (computed at booking time using system time)
  // If it doesn't exist (old bookings), fall back to startMinutes.
  final int windowStart =
      (booking['windowStartMinutes'] as int?) ?? startMinutes;

  // Read system time
  final systemSnap = await FirebaseFirestore.instance
      .collection('system')
      .doc('time')
      .get();

  final systemDate = systemSnap['date'];
  final String? systemTime = systemSnap['currentTime'];
  if (systemTime == null) {
    return;
  }

  // Only expire if same date
  if (systemDate != date) {
    return;
  }

  final parts = systemTime.split(':');
  if (parts.length != 2) {
    return;
  }

  final int nowMinutes =
      int.parse(parts[0]) * 60 + int.parse(parts[1]);
  const int checkInWindowMinutes = 10;

  // ⏰ If current system time is later than windowStart + 10 minutes → expire
  if (nowMinutes > windowStart + checkInWindowMinutes) {
    // Time passed, no check-in → expire booking and free room
    await bookingSnap.reference.update({
      'status': 'expired',
      'isCheckedIn': false,
    });

    await roomDoc.reference.update({
      'status': 'free',
      'currentReservationId': FieldValue.delete(),
    });
  }
}
