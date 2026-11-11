# WorkManager / Room instantiate generated classes reflectively.
-keep class androidx.work.** { *; }
-keep class * extends androidx.room.RoomDatabase { <init>(...); }
-keep class androidx.room.** { *; }
# Our components are referenced from the manifest / reflection.
-keep class dev.timely.timely.** { *; }
