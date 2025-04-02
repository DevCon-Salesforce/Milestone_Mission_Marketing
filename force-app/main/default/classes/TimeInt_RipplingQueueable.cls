/**
* @description     : Queueable job to fetch and insert time entries from Rippling within the last 3 weeks.
* @author          : Mitesh Mangukiya
* @last modified on: 2025-03-25
* @last modified by: Mitesh Mangukiya
*/

public with sharing class TimeInt_RipplingQueueable implements Queueable, Database.AllowsCallouts {
    
    private String initialRequestUrl;
    
    /**
    * Constructor
    * If nextLink is null, it builds the initial request with 3-week filter.
    */
    public TimeInt_RipplingQueueable(String nextLink) {
        if (String.isEmpty(nextLink)) {
            Date filterDate = Date.today().addDays(-21);
            String filter = EncodingUtil.urlEncode('pay_period.start_date gt ' + filterDate, 'UTF-8');
            
            this.initialRequestUrl = '/time-entries?' + filter;
        } else {
            this.initialRequestUrl = nextLink; 
        }
    }
    
    /**
    * Main execution method
    * - Loops through paginated API
    * - Collects results
    * - Performs DML at the end
    */
    public void execute(QueueableContext context) {
        TimeInt_RipplingService ripplingService = new TimeInt_RipplingService();
        String currentUrl = this.initialRequestUrl;
        
        Integer maxPages = 50;
        Integer currentPage = 0;
        
        List<TimeInt_RipplingDTO.Results> timeEntriesToInsert = new List<TimeInt_RipplingDTO.Results>();
        
        while (!String.isEmpty(currentUrl) && currentPage < maxPages) {

            TimeInt_RipplingDTO.TimeEntryWrapper responseWrapper;
            
            try {
                responseWrapper = ripplingService.getTimeEntry(currentUrl);
            } catch (Exception ex) {
                break;
            }
            
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
        }
        
        // Final DML after all pages have been fetched
        if (!timeEntriesToInsert.isEmpty()) {
            try {
                ripplingService.insertTimeEntries(timeEntriesToInsert);
            } catch (Exception dmlEx) {
                System.debug('DML failed after callout loop: ' + dmlEx.getMessage());
            }
        } else {
            System.debug('No time entries found for insertion.');
        }
    }
    
    /**
    * Cleans the next_link URL from Rippling by stripping domain and extra query parameters.
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