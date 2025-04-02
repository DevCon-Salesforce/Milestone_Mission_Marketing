/**
 * @description     : Service class for making REST API calls to Rippling's Time Entry and Job Code endpoints.
 *                    Handles callouts, parsing, and data transformation before inserting/upserting into Salesforce.
 *                    
 * @author          : adrienne@developmentconsultingpartners.com
 * @last modified on: 2025-04-01
 * @last modified by: Mitesh Mangukiya
 */
public with sharing class TimeInt_RipplingService extends RestClientLib {

    @TestVisible
    private class RipplingServiceException extends Exception {}
    @TestVisible
    private static final String NAMED_CREDENTIAL_NAME = 'RipplingNC';
    @TestVisible
    private static final String JOB_CODE_PATH = '/job-codes/';
    @TestVisible
    public static TimeInt_RipplingDTO.JobCode jobCode { get; private set; }
    @TestVisible
    public static List<TimeInt_RipplingDTO.Results> timeEntryResults { get; private set; }
 
    /**
    * @description Constructor that is required by RestClientLib.
    * Sets the Named credential that all methods invoked by this class are
    * tied to.
    */
    public TimeInt_RipplingService() {
        super(NAMED_CREDENTIAL_NAME);
    }

    public void getJobCode(String url) {
        if (String.isBlank(url)) {
            url = JOB_CODE_PATH;
        }

        HttpResponse httpResp = get(url);
        if (httpResp.getStatusCode() != 200) {
            throw new RipplingServiceException('Failed to get job codes. Status code: ' + httpResp.getStatusCode() +
                                               ' Body: ' + httpResp.getBody());
        }

        String readyJson = TimeInt_RipplingDTO.preParse(httpResp.getBody());
        jobCode = TimeInt_RipplingDTO.parseJobCode(readyJson);
    }

    public void insertJobCodes(TimeInt_RipplingDTO.JobCode jobCode) {
        List<Job_Code__c> jobCodesToInsert = new List<Job_Code__c>();
        for (TimeInt_RipplingDTO.Results result : jobCode.results) {
            Job_Code__c jc = new Job_Code__c();
            jc.Job_Code_External_Id__c = result.id;
            //jc.Name = result.name;
            jobCodesToInsert.add(jc);
        }
        insertRecords(jobCodesToInsert);
    }

    /**
     * Makes a GET call to retrieve time entries.
     */
    public TimeInt_RipplingDTO.TimeEntryWrapper getTimeEntry(String fullUrl) {
        String path = fullUrl.contains('?') ? fullUrl.substringBefore('?') : fullUrl;
        String query = fullUrl.contains('?') ? fullUrl.substringAfter('?') : '';
        
        // Split query into map for re-use
        Map<String, String> queryMap = new Map<String, String>();
        for (String pair : query.split('&')) {
            List<String> parts = pair.split('=');
            if (parts.size() == 2) {
                queryMap.put(parts[0], parts[1].replace('%20', ' '));
            }
        }
        
        HttpResponse resp = this.getEncoded(path, queryMap);
        
        if (resp.getStatusCode() != 200) {
            throw new RipplingServiceException(
                'Invalid response. Status code: ' + resp.getStatusCode() +
                ' Body: ' + resp.getBody()
            );
        }
        
        String cleanedJson = TimeInt_RipplingDTO.preParse(resp.getBody());
        return (TimeInt_RipplingDTO.TimeEntryWrapper)
            JSON.deserialize(cleanedJson, TimeInt_RipplingDTO.TimeEntryWrapper.class);
    }


    /**
     * Inserts or upserts time entry records into Salesforce after mapping and de-duplication.
     */
    public void insertTimeEntries(List<TimeInt_RipplingDTO.Results> timeEntries) {
        List<Time_Entry__c> entriesToInsert = new List<Time_Entry__c>();
        Map<String, Id> jobCodeMap = new Map<String, Id>();
        Map<String, String> jobCodeNameMap = new Map<String, String>(); 
        Map<String, Id> workerMap = new Map<String, Id>();
        Map<String, Id> caseMap = new Map<String, Id>();
        Set<String> jobCodeIds = new Set<String>();
        Set<String> caseCodes = new Set<String>();
        Set<String> externalIds = new Set<String>();
        Map<String, Time_Entry__c> existingTimeEntries = new Map<String, Time_Entry__c>();

        // First pass: collect job codes and external IDs
        for (TimeInt_RipplingDTO.Results result : timeEntries) {
            if (result.job_shifts == null || result.job_shifts.isEmpty()) continue;

            for (TimeInt_RipplingDTO.JobShifts jobShift : result.job_shifts) {
                for (String jobCodeId : jobShift.job_codes_id) {
                    jobCodeIds.add(jobCodeId);
                    externalIds.add(result.id + '-' + jobCodeId);
                }
            }
        }

        // Query existing entries to avoid duplicate upserts
        if (!externalIds.isEmpty()) {
            for (Time_Entry__c entry : [
                SELECT Id, External_Time_Entry_ID__c 
                FROM Time_Entry__c 
                WHERE External_Time_Entry_ID__c IN :externalIds
            ]) {
                existingTimeEntries.put(entry.External_Time_Entry_ID__c, entry);
            }
        }

        // Map job codes to IDs and parse related case codes from job code name
        if (!jobCodeIds.isEmpty()) {
            for (Job_Code__c jobCode : [
                SELECT Id, Job_Code_External_ID__c, Name
                FROM Job_Code__c
                WHERE Job_Code_External_ID__c IN :jobCodeIds
            ]) {
                jobCodeMap.put(jobCode.Job_Code_External_ID__c, jobCode.Id);
                jobCodeNameMap.put(jobCode.Job_Code_External_ID__c, jobCode.Name);

                String[] nameParts = jobCode.Name.split('-');
                if (nameParts.size() > 2) {
                    caseCodes.add(nameParts[2].trim());
                } else {
                    System.debug('Unexpected jobCode format: ' + jobCode.Name);
                }
            }
        }

        // Fetch matching Case records
        if (!caseCodes.isEmpty()) {
            for (Case c : [
                SELECT Id, Case_Code__c 
                FROM Case 
                WHERE Case_Code__c IN :caseCodes
            ]) {
                caseMap.put(c.Case_Code__c, c.Id);
            }
        }

        // Build worker map
        Set<String> workerIds = new Set<String>();
        for (TimeInt_RipplingDTO.Results result : timeEntries) {
            if (result.worker_id != null) {
                workerIds.add(result.worker_id);
            }
        }
        if (!workerIds.isEmpty()) {
            for (Worker__c worker : [
                SELECT Id, Worker_External_ID__c
                FROM Worker__c
                WHERE Worker_External_ID__c IN :workerIds
            ]) {
                workerMap.put(worker.Worker_External_ID__c, worker.Id);
            }
        }

        // Get fallback case ID from custom setting
        Id defaultCaseId = null;
        Time_Entry_Integrations__c settings = Time_Entry_Integrations__c.getInstance();
        if (settings != null) {
            defaultCaseId = settings.Fallback_Case_Id__c;
        }
	
        Date lastSyncRunDate = (settings != null && settings.Last_Sync_Run_Date__c != null) 
        ? settings.Last_Sync_Run_Date__c 
        : null;
		
        // Build new Time_Entry__c records or update existing ones
        for (TimeInt_RipplingDTO.Results result : timeEntries) {
            date updatedDate = date.valueOf(result.updated_at);
            if (updatedDate != null && lastSyncRunDate != null && updatedDate <= lastSyncRunDate) {
                continue; 
            }
            for (TimeInt_RipplingDTO.JobShifts jobShift : result.job_shifts) {
                for (String jobCodeId : jobShift.job_codes_id) {
                    String externalId = result.id + '-' + jobCodeId;

                    Time_Entry__c entry = existingTimeEntries.containsKey(externalId) 
                        ? existingTimeEntries.get(externalId) 
                        : new Time_Entry__c();

                    entry.External_Time_Entry_ID__c = externalId;
                    entry.Start_Time__c = TimeInt_RipplingDTO.createDate(jobShift.start_time);
                    entry.End_Time__c = TimeInt_RipplingDTO.createDate(jobShift.end_time);
                    entry.Time_Entry_Type__c = 'Rippling';
                    entry.Status__c = result.status;

                    if (jobCodeNameMap.containsKey(jobCodeId)) {
                        String[] nameParts = jobCodeNameMap.get(jobCodeId).split('-');
                        String caseCode = (nameParts.size() > 2) ? nameParts[2].trim() : null;
                        entry.Case__c = (caseCode != null && caseMap.containsKey(caseCode)) 
                                        ? caseMap.get(caseCode) : defaultCaseId;
                    } else {
                        entry.Case__c = defaultCaseId;
                    }

                    if (workerMap.containsKey(result.worker_id)) {
                        entry.Worker__c = workerMap.get(result.worker_id);
                    }
                    entry.Worker_Id_txt__c = result.worker_id;

                    if (jobCodeMap.containsKey(jobCodeId)) {
                        entry.Job_Code__c = jobCodeMap.get(jobCodeId);
                    }
                    entry.Job_Code_Id_txt__c = jobCodeId;

                    entriesToInsert.add(entry);
                }
            }
        }

        // Upsert unique entries
        Map<String, Time_Entry__c> uniqueEntries = new Map<String, Time_Entry__c>();
        for (Time_Entry__c e : entriesToInsert) {
            uniqueEntries.put(e.External_Time_Entry_ID__c, e);
        }

        if (!uniqueEntries.isEmpty()) {
            upsertRecords(new List<Time_Entry__c>(uniqueEntries.values()));
        }
    }

    /**
     * Safe insert for generic sObjects
     */
    public void insertRecords(List<sObject> recordsToInsert) {
        try {
            insert recordsToInsert;
        } catch (Exception ex) {
            System.debug('Insert failed: ' + ex.getMessage());
            throw new RipplingServiceException();
        }
    }

    /**
     * Safe upsert for Time_Entry__c records using external ID.
     */
    public void upsertRecords(List<Time_Entry__c> recordsToUpsert) {
        try {
            upsert recordsToUpsert External_Time_Entry_ID__c;
        } catch (DmlException ex) {
            System.debug('Upsert failed: ' + ex.getMessage());
            throw new RipplingServiceException();
        }
    }
}