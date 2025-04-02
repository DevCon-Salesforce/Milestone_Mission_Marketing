/**
 * @description     : Batch job to fetch and insert time entries from Rippling within the last 3 weeks,
 *                    with pagination support. Updates the Last_Sync_Run_Date__c custom setting once complete.
 * @author          : Mitesh Mangukiya
 * @last modified on: 2025-04-02
 * @last modified by: Mitesh Mangukiya 
 */
public with sharing class TimeInt_RipplingBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    // Configurable max page limit
    private Integer maxPages = 50;

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([SELECT Id FROM User LIMIT 1]);
    }
	
    /**
     * Core logic of the batch execution:
     * - Builds API filter for time entries in the last 3 weeks
     * - Uses paginated API to fetch entries (up to `maxPages`)
     * - Filters out incomplete entries (null status)
     * - Accumulates valid entries and performs bulk insert
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        TimeInt_RipplingService ripplingService = new TimeInt_RipplingService();

        // Format the date as yyyy-MM-dd for 3 weeks ago
        String filterDate = DateTime.newInstance(Date.today().addDays(-21), Time.newInstance(0, 0, 0, 0)).format('yyyy-MM-dd');
        String filter = 'pay_period.start_date gt ' + filterDate;
        String orderBy = 'created_at asc';
        String currentUrl = '/time-entries?filter=' + filter + '&order_by=' + orderBy;

        List<TimeInt_RipplingDTO.Results> timeEntriesToInsert = new List<TimeInt_RipplingDTO.Results>();
        Integer currentPage = 0;

        while (!String.isEmpty(currentUrl) && currentPage < maxPages) {
            try {
                TimeInt_RipplingDTO.TimeEntryWrapper responseWrapper = ripplingService.getTimeEntry(currentUrl);
                for (TimeInt_RipplingDTO.Results entry : responseWrapper.results) {
                    if (entry.status != null) {
                        timeEntriesToInsert.add(entry);
                    }
                }

                if (!String.isEmpty(responseWrapper.next_link)) {
                    currentUrl = cleanNextLink(responseWrapper.next_link);
                } else {
                    break;
                }
                currentPage++;
            } catch (Exception ex) {
                System.debug('Callout failed: ' + ex.getMessage());
                break;
            }
        }

        if (!timeEntriesToInsert.isEmpty()) {
            try {
                ripplingService.insertTimeEntries(timeEntriesToInsert);
                System.debug('Inserted ' + timeEntriesToInsert.size() + ' time entries.');
            } catch (Exception dmlEx) {
                System.debug('DML failed: ' + dmlEx.getMessage());
            }
        } else {
            System.debug('No time entries to insert.');
        }
    }

    /**
     * Final step after batch execution:
     * - Updates custom setting `Last_Sync_Run_Date__c` to today’s date
     * - Indicates successful sync completion
     * - Catches and logs any errors during update
     */
    public void finish(Database.BatchableContext context) {
        try {
            Time_Entry_Integrations__c settings = [SELECT Id, Last_Sync_Run_Date__c FROM Time_Entry_Integrations__c LIMIT 1];
            settings.Last_Sync_Run_Date__c = Date.today();
            update settings;

            System.debug('Updated Last_Sync_Run_Date__c to ' + settings.Last_Sync_Run_Date__c);
        } catch (Exception ex) {
            System.debug('Error updating Last_Sync_Run_Date__c: ' + ex.getMessage());
        }
    }

    /**
     * Cleans up the `next_link` URL returned from Rippling API:
     * - Removes domain prefix if present
     * - Strips duplicate or unnecessary filters
     * - Ensures the next page callout uses correct relative path
     *
     * @param fullUrl Full URL from the API `next_link`
     * @return A cleaned relative path for the next API call
     */
    private String cleanNextLink(String fullUrl) {
        if (String.isEmpty(fullUrl)) return null;

        String baseUrl = 'https://rest.ripplingapis.com';
        String cleanedUrl = fullUrl.startsWith(baseUrl) ? fullUrl.replace(baseUrl, '') : fullUrl;

        // Strip any duplicate filter from next_link
        if (cleanedUrl.contains('&pay_period')) {
            cleanedUrl = cleanedUrl.substringBefore('&pay_period');
        }

        return cleanedUrl;
    }
}