/**
 * Validates the three "RH Lock Time Entries" record-triggered flows
 * (Create / Update / Delete) on ResourceHeroApp__Resource_Forecast__c.
 *
 * What the flows promise:
 *   - A user WITHOUT the "Edit Locked Time Entries" custom permission cannot
 *     add hours to, change hours/notes on, or delete a time entry whose
 *     Forecast Date is before the lock cutoff.
 *   - The cutoff is driven by the flow constant LockMode (Days / Week / Month)
 *     and, for Days, LockDays.
 *   - Only standard project assignments are locked. PTO, holiday, capacity and
 *     snapshot rows are never touched (Is_Standard_Assignment__c = false).
 *   - Entries with no hours (null or 0) are never locked on create/delete, and
 *     an update that touches neither Actual hours nor Actual Notes is allowed.
 *   - A user WITH the custom permission (via the "Time Entry Lock Bypass"
 *     permission set) is never blocked.
 *
 * Apex cannot read a flow constant, so LOCK_MODE / LOCK_DAYS below mirror the
 * flow config. If you change the flow constants, change them here too and
 * re-run the tests. Every test is written so that a mismatch fails loudly.
 */
@IsTest
private class RH_Lock_Time_Entries_Test {
   // ---- Keep in sync with the LockMode / LockDays constants in all three flows ----
   private static final String LOCK_MODE = 'Week'; // 'Days' | 'Week' | 'Month'
   private static final Integer LOCK_DAYS = 7; // only used when LOCK_MODE = 'Days'

   private static final String BYPASS_PERMSET = 'Time_Entry_Lock_Bypass';
   private static final String LOCKED_USER = 'rh.lock.locked@example.com.test';
   private static final String BYPASS_USER = 'rh.lock.bypass@example.com.test';
   private static final String ERROR_PREFIX = 'Locked:';

   // =====================================================================
   // Date helpers
   // =====================================================================

   /** First day that is NOT locked. Anything strictly before this is locked. */
   private static Date cutoff() {
      Date today = Date.today();
      if (LOCK_MODE == 'Days') {
         return today.addDays(-LOCK_DAYS);
      }
      if (LOCK_MODE == 'Week') {
         // Monday of the current week. 1900-01-08 was a Monday, same anchor the flow formula uses.
         Integer offset = Math.mod(Date.newInstance(1900, 1, 8).daysBetween(today), 7);
         return today.addDays(-offset);
      }
      if (LOCK_MODE == 'Month') {
         return today.toStartOfMonth();
      }
      throw new IllegalArgumentException('Unknown LOCK_MODE ' + LOCK_MODE);
   }

   /** Last locked day: the day immediately before the cutoff. */
   private static Date lockedDate() {
      return cutoff().addDays(-1);
   }

   /** First open day: the cutoff itself. Proves the comparison is strictly "less than". */
   private static Date firstOpenDate() {
      return cutoff();
   }

   /** Far enough back to be locked under every mode, regardless of config. */
   private static Date farPastDate() {
      return Date.today().addDays(-400);
   }

   /** The mode-specific fragment the flow's error message must contain. */
   private static String expectedMessageFragment() {
      if (LOCK_MODE == 'Days') {
         return 'is more than ' + LOCK_DAYS + ' days old';
      }
      if (LOCK_MODE == 'Week') {
         return 'is before this week';
      }
      return 'is before this month';
   }

   // =====================================================================
   // Setup
   // =====================================================================

   @TestSetup
   static void setup() {
      // Setup-object DML (User, PermissionSetAssignment) must be isolated from
      // regular DML to avoid MIXED_DML_OPERATION.
      System.runAs(new User(Id = UserInfo.getUserId())) {
         Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
         List<User> users = new List<User>{ buildUser(admin.Id, LOCKED_USER, 'Locked'), buildUser(admin.Id, BYPASS_USER, 'Bypass') };
         insert users;

         PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :BYPASS_PERMSET LIMIT 1];
         insert new PermissionSetAssignment(AssigneeId = users[1].Id, PermissionSetId = ps.Id);
      }

      ResourceHeroApp__Resource__c res = new ResourceHeroApp__Resource__c(Name = 'Lock Test Resource', ResourceHeroApp__Team__c = 'Development Team', ResourceHeroApp__User__c = UserInfo.getUserId());
      insert res;

      ResourceHeroApp__RH_Project__c proj = new ResourceHeroApp__RH_Project__c(Name = 'Lock Test Project');
      insert proj;

      insert new ResourceHeroApp__Resource_Assignment__c(ResourceHeroApp__Resource__c = res.Id, ResourceHeroApp__RH_Project__c = proj.Id, ResourceHeroApp__Role__c = 'Developer', ResourceHeroApp__Rate__c = 5);
   }

   private static User buildUser(Id profileId, String username, String lastName) {
      return new User(
         ProfileId = profileId,
         Username = username,
         Email = username,
         Alias = lastName.left(8).toLowerCase(),
         FirstName = 'RH Lock',
         LastName = lastName,
         TimeZoneSidKey = 'America/New_York',
         LocaleSidKey = 'en_US',
         EmailEncodingKey = 'UTF-8',
         LanguageLocaleKey = 'en_US'
      );
   }

   private static User lockedUser() {
      return [SELECT Id FROM User WHERE Username = :LOCKED_USER];
   }

   private static User bypassUser() {
      return [SELECT Id FROM User WHERE Username = :BYPASS_USER];
   }

   private static ResourceHeroApp__Resource_Assignment__c standardAssignment() {
      return [SELECT Id, ResourceHeroApp__Is_Standard__c FROM ResourceHeroApp__Resource_Assignment__c WHERE ResourceHeroApp__RH_Project__c != NULL LIMIT 1];
   }

   /**
    * Builds a NON-standard (capacity-type) assignment. Resource Hero's own
    * triggers refuse manual inserts of capacity rows, so they are switched off
    * for this test transaction via the RHA_Settings custom setting. The lock
    * flows do not depend on those triggers.
    */
   private static ResourceHeroApp__Resource_Assignment__c nonStandardAssignment() {
      insert new ResourceHeroApp__RHA_Settings__c(
         SetupOwnerId = UserInfo.getOrganizationId(),
         ResourceHeroApp__Disable_Trigger_RH_Capacity__c = true,
         ResourceHeroApp__Disable_Trigger_Resource_Assignment__c = true,
         ResourceHeroApp__Disable_Trigger_Resource_Forecast__c = true
      );

      ResourceHeroApp__Resource__c res = [SELECT Id FROM ResourceHeroApp__Resource__c LIMIT 1];
      ResourceHeroApp__RH_Capacity__c cap = new ResourceHeroApp__RH_Capacity__c(
         ResourceHeroApp__Resource__c = res.Id,
         ResourceHeroApp__Start_Date__c = Date.today().addYears(-2),
         ResourceHeroApp__End_Date__c = Date.today().addYears(1),
         ResourceHeroApp__Monday__c = 8,
         ResourceHeroApp__Tuesday__c = 8,
         ResourceHeroApp__Wednesday__c = 8,
         ResourceHeroApp__Thursday__c = 8,
         ResourceHeroApp__Friday__c = 8,
         ResourceHeroApp__Saturday__c = 0,
         ResourceHeroApp__Sunday__c = 0
      );
      insert cap;

      ResourceHeroApp__Resource_Assignment__c ra = new ResourceHeroApp__Resource_Assignment__c(ResourceHeroApp__Resource__c = res.Id, ResourceHeroApp__RH_Capacity__c = cap.Id);
      insert ra;

      ra = [SELECT Id, ResourceHeroApp__Is_Standard__c FROM ResourceHeroApp__Resource_Assignment__c WHERE Id = :ra.Id];
      System.assertEquals(false, ra.ResourceHeroApp__Is_Standard__c, 'Capacity assignment should not be standard');
      return ra;
   }

   private static ResourceHeroApp__Resource_Forecast__c entry(Id assignmentId, Date forecastDate, Decimal actual, String notes) {
      return new ResourceHeroApp__Resource_Forecast__c(
         ResourceHeroApp__Resource_Assignment__c = assignmentId,
         ResourceHeroApp__ForecastDate__c = forecastDate,
         ResourceHeroApp__Forecast__c = 8, // keeps the row valid for RH's own "at least one hour" rule
         ResourceHeroApp__Actual__c = actual,
         ResourceHeroApp__Actual_Notes__c = notes
      );
   }

   /** Seeds an entry as the bypass user so the Create flow cannot interfere with setup. */
   private static ResourceHeroApp__Resource_Forecast__c seedEntry(Id assignmentId, Date forecastDate, Decimal actual, String notes) {
      ResourceHeroApp__Resource_Forecast__c rf = entry(assignmentId, forecastDate, actual, notes);
      System.runAs(bypassUser()) {
         insert rf;
      }
      return [SELECT Id, ResourceHeroApp__ForecastDate__c, ResourceHeroApp__Actual__c, ResourceHeroApp__Actual_Notes__c, ResourceHeroApp__Forecast__c, Is_Standard_Assignment__c FROM ResourceHeroApp__Resource_Forecast__c WHERE Id = :rf.Id];
   }

   // =====================================================================
   // Assertion helpers
   // =====================================================================

   private static void assertLocked(Database.SaveResult sr, String context) {
      System.assertEquals(false, sr.isSuccess(), context + ': expected the lock flow to block this, but it succeeded');
      assertLockMessage(sr.getErrors()[0].getMessage(), context);
   }

   private static void assertLocked(Database.DeleteResult dr, String context) {
      System.assertEquals(false, dr.isSuccess(), context + ': expected the lock flow to block this, but it succeeded');
      assertLockMessage(dr.getErrors()[0].getMessage(), context);
   }

   private static void assertLockMessage(String msg, String context) {
      System.assert(msg.contains(ERROR_PREFIX), context + ': error was not raised by the lock flow. Got: ' + msg);
      System.assert(msg.contains(expectedMessageFragment()), context + ': error did not match LOCK_MODE=' + LOCK_MODE + '. Expected fragment "' + expectedMessageFragment() + '" in: ' + msg);
   }

   private static void assertAllowed(Database.SaveResult sr, String context) {
      String err = sr.isSuccess() ? '' : sr.getErrors()[0].getMessage();
      System.assert(sr.isSuccess(), context + ': expected this to be allowed, but it failed with: ' + err);
   }

   private static void assertAllowed(Database.DeleteResult dr, String context) {
      String err = dr.isSuccess() ? '' : dr.getErrors()[0].getMessage();
      System.assert(dr.isSuccess(), context + ': expected this to be allowed, but it failed with: ' + err);
   }

   // =====================================================================
   // Sanity: the test's cutoff math agrees with the flow's cutoff formula.
   // If LOCK_MODE here drifts from the flow, this fails first and explains why.
   // =====================================================================

   @IsTest
   static void cutoffBoundary_matchesFlow() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult locked = Database.insert(entry(ra, lockedDate(), 1, null), false);
         Database.SaveResult open = Database.insert(entry(ra, firstOpenDate(), 1, null), false);
         Test.stopTest();
         assertLocked(locked, 'Day before cutoff (' + lockedDate() + ')');
         assertAllowed(open, 'Cutoff day itself (' + firstOpenDate() + ') must be open; check LOCK_MODE matches the flow');
      }
   }

   // =====================================================================
   // CREATE
   // =====================================================================

   @IsTest
   static void create_pastEntryWithHours_isBlocked() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, lockedDate(), 4, 'late entry'), false);
         Test.stopTest();
         assertLocked(sr, 'Create with hours on locked date');
      }
   }

   @IsTest
   static void create_farPastEntryWithHours_isBlocked() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, farPastDate(), 4, null), false);
         Test.stopTest();
         assertLocked(sr, 'Create with hours far in the past');
      }
   }

   @IsTest
   static void create_todayWithHours_isAllowed() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, Date.today(), 4, 'today'), false);
         Test.stopTest();
         assertAllowed(sr, 'Create with hours today');
      }
   }

   @IsTest
   static void create_futureWithHours_isAllowed() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, Date.today().addDays(30), 4, null), false);
         Test.stopTest();
         assertAllowed(sr, 'Create with hours in the future');
      }
   }

   @IsTest
   static void create_pastEntryWithZeroHours_isAllowed() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, lockedDate(), 0, null), false);
         Test.stopTest();
         assertAllowed(sr, 'Create with 0 hours on locked date (forecast only)');
      }
   }

   @IsTest
   static void create_pastEntryWithNullHours_isAllowed() {
      Id ra = standardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, lockedDate(), null, null), false);
         Test.stopTest();
         assertAllowed(sr, 'Create with null hours on locked date (forecast only)');
      }
   }

   @IsTest
   static void create_pastEntryWithHours_bypassUser_isAllowed() {
      Id ra = standardAssignment().Id;
      System.runAs(bypassUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, farPastDate(), 4, 'admin correction'), false);
         Test.stopTest();
         assertAllowed(sr, 'Create with hours on locked date as bypass user');
      }
   }

   @IsTest
   static void create_pastEntryWithHours_nonStandardAssignment_isAllowed() {
      Id ra = nonStandardAssignment().Id;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.SaveResult sr = Database.insert(entry(ra, farPastDate(), 4, null), false);
         Test.stopTest();
         assertAllowed(sr, 'Create with hours on locked date for a non-standard (capacity) assignment');
      }
   }

   // =====================================================================
   // UPDATE
   // =====================================================================

   @IsTest
   static void update_hoursOnLockedEntry_isBlocked() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), 4, 'original');
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Actual__c = 6;
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertLocked(sr, 'Update hours on locked entry');
      }
      System.assertEquals(4, [SELECT ResourceHeroApp__Actual__c FROM ResourceHeroApp__Resource_Forecast__c WHERE Id = :rf.Id].ResourceHeroApp__Actual__c, 'Hours must be unchanged');
   }

   @IsTest
   static void update_notesOnLockedEntry_isBlocked() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), 4, 'original');
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Actual_Notes__c = 'edited';
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertLocked(sr, 'Update notes on locked entry');
      }
      System.assertEquals('original', [SELECT ResourceHeroApp__Actual_Notes__c FROM ResourceHeroApp__Resource_Forecast__c WHERE Id = :rf.Id].ResourceHeroApp__Actual_Notes__c, 'Notes must be unchanged');
   }

   @IsTest
   static void update_clearHoursOnLockedEntry_isBlocked() {
      // Zeroing out hours is still a change to Actual and must be blocked.
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, farPastDate(), 4, null);
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Actual__c = 0;
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertLocked(sr, 'Clear hours on locked entry');
      }
   }

   @IsTest
   static void update_addHoursToLockedForecastOnlyEntry_isBlocked() {
      // A forecast-only row (no actuals yet) in the locked period cannot have hours added later.
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), null, null);
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Actual__c = 8;
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertLocked(sr, 'Add hours to locked forecast-only entry');
      }
   }

   @IsTest
   static void update_forecastHoursOnLockedEntry_isAllowed() {
      // Entry criteria only watch Actual hours and Actual Notes; other fields stay editable.
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), 4, 'original');
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Forecast__c = 10;
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertAllowed(sr, 'Update forecast (planned) hours on locked entry');
      }
   }

   @IsTest
   static void update_hoursOnOpenEntry_isAllowed() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, firstOpenDate(), 4, 'original');
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Actual__c = 6;
         rf.ResourceHeroApp__Actual_Notes__c = 'edited';
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertAllowed(sr, 'Update hours and notes on open entry');
      }
   }

   @IsTest
   static void update_hoursOnLockedEntry_bypassUser_isAllowed() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, farPastDate(), 4, 'original');
      System.runAs(bypassUser()) {
         rf.ResourceHeroApp__Actual__c = 6;
         rf.ResourceHeroApp__Actual_Notes__c = 'admin correction';
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertAllowed(sr, 'Update hours and notes on locked entry as bypass user');
      }
   }

   @IsTest
   static void update_hoursOnLockedEntry_nonStandardAssignment_isAllowed() {
      Id ra = nonStandardAssignment().Id;
      ResourceHeroApp__Resource_Forecast__c rf = entry(ra, farPastDate(), 4, null);
      insert rf;
      System.runAs(lockedUser()) {
         rf.ResourceHeroApp__Actual__c = 6;
         rf.ResourceHeroApp__Actual_Notes__c = 'edited';
         Test.startTest();
         Database.SaveResult sr = Database.update(rf, false);
         Test.stopTest();
         assertAllowed(sr, 'Update hours on locked date for a non-standard (capacity) assignment');
      }
   }

   // =====================================================================
   // DELETE
   // =====================================================================

   @IsTest
   static void delete_lockedEntryWithHours_isBlocked() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), 4, null);
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.DeleteResult dr = Database.delete(rf, false);
         Test.stopTest();
         assertLocked(dr, 'Delete locked entry with hours');
      }
      System.assertEquals(1, [SELECT COUNT() FROM ResourceHeroApp__Resource_Forecast__c WHERE Id = :rf.Id], 'Entry must still exist');
   }

   @IsTest
   static void delete_lockedEntryWithZeroHours_isAllowed() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), 0, null);
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.DeleteResult dr = Database.delete(rf, false);
         Test.stopTest();
         assertAllowed(dr, 'Delete locked forecast-only entry (0 hours)');
      }
   }

   @IsTest
   static void delete_lockedEntryWithNullHours_isAllowed() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, lockedDate(), null, null);
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.DeleteResult dr = Database.delete(rf, false);
         Test.stopTest();
         assertAllowed(dr, 'Delete locked forecast-only entry (null hours)');
      }
   }

   @IsTest
   static void delete_openEntryWithHours_isAllowed() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, firstOpenDate(), 4, null);
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.DeleteResult dr = Database.delete(rf, false);
         Test.stopTest();
         assertAllowed(dr, 'Delete open entry with hours');
      }
   }

   @IsTest
   static void delete_lockedEntryWithHours_bypassUser_isAllowed() {
      ResourceHeroApp__Resource_Forecast__c rf = seedEntry(standardAssignment().Id, farPastDate(), 4, null);
      System.runAs(bypassUser()) {
         Test.startTest();
         Database.DeleteResult dr = Database.delete(rf, false);
         Test.stopTest();
         assertAllowed(dr, 'Delete locked entry with hours as bypass user');
      }
   }

   @IsTest
   static void delete_lockedEntryWithHours_nonStandardAssignment_isAllowed() {
      Id ra = nonStandardAssignment().Id;
      ResourceHeroApp__Resource_Forecast__c rf = entry(ra, farPastDate(), 4, null);
      insert rf;
      System.runAs(lockedUser()) {
         Test.startTest();
         Database.DeleteResult dr = Database.delete(rf, false);
         Test.stopTest();
         assertAllowed(dr, 'Delete locked entry with hours for a non-standard (capacity) assignment');
      }
   }

   // =====================================================================
   // BULK: the flows are before-save and must behave per record in one DML.
   // =====================================================================

   @IsTest
   static void create_bulkMixedDates_blocksOnlyLockedRows() {
      Id ra = standardAssignment().Id;
      List<ResourceHeroApp__Resource_Forecast__c> rows = new List<ResourceHeroApp__Resource_Forecast__c>();
      for (Integer i = 0; i < 5; i++) {
         rows.add(entry(ra, lockedDate().addDays(-i), 1, null)); // locked
         rows.add(entry(ra, firstOpenDate().addDays(i), 1, null)); // open
      }
      System.runAs(lockedUser()) {
         Test.startTest();
         List<Database.SaveResult> results = Database.insert(rows, false);
         Test.stopTest();
         for (Integer i = 0; i < results.size(); i++) {
            if (Math.mod(i, 2) == 0) {
               assertLocked(results[i], 'Bulk row ' + i + ' (' + rows[i].ResourceHeroApp__ForecastDate__c + ')');
            } else {
               assertAllowed(results[i], 'Bulk row ' + i + ' (' + rows[i].ResourceHeroApp__ForecastDate__c + ')');
            }
         }
      }
   }
}
