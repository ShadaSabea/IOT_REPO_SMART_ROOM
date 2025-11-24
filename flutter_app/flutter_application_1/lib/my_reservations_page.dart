import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MyReservationsPage extends StatelessWidget {
  const MyReservationsPage({super.key});

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
              roomNames[doc.id] = (data['name'] ?? 'Unknown room').toString();
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
              if (docs.isEmpty) {
                return const Center(child: Text("You have no reservations."));
              }

              // Today (date only)
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);

              // Filter to today & future dates
              final filtered = docs.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final dateStr = data["date"] as String?;
                if (dateStr == null) return false;
                try {
                  final d = DateTime.parse(dateStr);
                  final onlyDate = DateTime(d.year, d.month, d.day);
                  return !onlyDate.isBefore(today); // keep >= today
                } catch (_) {
                  return false;
                }
              }).toList();

              // Sort by (date, startTime)
              filtered.sort((a, b) {
                final aData = a.data() as Map<String, dynamic>;
                final bData = b.data() as Map<String, dynamic>;

                final ad = DateTime.parse(aData["date"]);
                final bd = DateTime.parse(bData["date"]);
                final cmp = ad.compareTo(bd);
                if (cmp != 0) return cmp;

                final aStart = (aData["startTime"] ?? 0) as int;
                final bStart = (bData["startTime"] ?? 0) as int;
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
                  final data = doc.data() as Map<String, dynamic>;

                  final roomId = data["roomId"] as String? ?? "";
                  final roomName = roomNames[roomId] ?? "Unknown room";

                  final date = data["date"] as String? ?? "";
                  final pin = data["pin"]?.toString() ?? "----";
                  final startMinutes = (data["startTime"] ?? 0) as int;
                  final endMinutes = (data["endTime"] ?? 0) as int;

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

  static String _formatTime(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return "$h:$m";
  }
}