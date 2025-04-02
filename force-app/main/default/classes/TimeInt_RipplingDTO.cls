/**
 * @description       :
 * @author            : adrienne@developmentconsultingpartners.com
 * @group             :
 * @last modified on  : 03-25-2025
 * @last modified by  : Mitesh Mangukiya
 **/
@SuppressWarnings('PMD.PropertyNamingConventions')
public with sharing class TimeInt_RipplingDTO {
  /**
   * @description - Translates a Rippling API response for JobCode into a RipplingDTO.JobCode Object
   * @param rawJson - String - Raw json returned from httpResponse.getBody()
   */
  public static JobCode parseJobCode(String rawJson) {
    String sanitizedJson = TimeInt_RipplingDTO.preParse(rawJson);
    System.debug('**sanitizedJSON: ' + sanitizedJson);
    return (JobCode) Json.deserialize(sanitizedJson, TimeInt_RipplingDTO.JobCode.class);
  }

  public static String preParse(String unsanitizedJson) {
    // number, __meta
    String sanitized = unsanitizedJson.replaceAll(
      '"number"',
      '"employee_number"'
    );

    return sanitized.replaceAll('"__meta"', '"metadata"');
  }

  /// The following classes and properties are deserialization objects

  public class JobCode {
    public List<results> results { get; set; }
    public String next_link { get; set; }
  }

  /**
   * @Added by : Mitesh Mangukiya
   * @Date : 3/25/2025
   * @description : Parses JSON for time entries (timesheet data) from Rippling and returns a list of Results (entries)
   */
  public static List<Results> parseTimeEntry(String rawJson) {

        String sanitizedJson = TimeInt_RipplingDTO.preParse(rawJson);
		System.debug('**sanitizedJSON: ' + sanitizedJson);

        // Deserialize sanitized JSON into TimeEntryWrapper, which contains a list of time entries
        TimeEntryWrapper wrapper = (TimeEntryWrapper) JSON.deserialize(sanitizedJson, TimeEntryWrapper.class);
		system.debug('wrapper--'+wrapper);
        system.debug('wrapper.results--'+wrapper.results);

        return wrapper.results;
	}
    
   /**
   * @Added by : Mitesh Mangukiya
   * @Date : 3/25/2025
   * @description : Wrapper class for paginated time entries response
   */
    public class TimeEntryWrapper {
		public List<Results> results;
		public String next_link { get; set; }
    }
	
    @SuppressWarnings('PMD.ExcessivePublicCount')
    public class Results {
        public String id;
        public String created_at;
        public String updated_at;
        public String worker_id;
        public List<JobShifts> job_shifts;
        public PayPeriod pay_period;
        public String status;
    }

    public class JobShifts {
        public String start_time;
        public String end_time;
        public List<String> job_codes_id;
        public Boolean is_hours_only_input;
    }

    public class PayPeriod {
        public String start_date;
        public String end_date;
        public String pay_schedule_id;
    }
    
  public class Segments {
    public String display_name { get; set; }
    public String end_time { get; set; }
    public list<String> job_codes_id { get; set; }
    public String start_time { get; set; }
    public String ot_multiplier { get; set; }
    public String pay_rate { get; set; }
    public String break_type_id { get; set; }
  }
    
  public class RedactedFields {
    public String name { get; set; }
    public String reason { get; set; }
  }
    
  public class Location {
    public String work_location_id { get; set; }
    public String type { get; set; } 
  }
    
  public class Metadata {
    public list<RedactedFields> redacted_fields { get; set; }
  }

  Public static DateTime createDate(String jsonDateTime) {
    jsonDateTime = jsonDateTime.subString(0, 19);
    jsonDateTime = jsonDateTime.replace('T', ' ');
    DateTime dt = DateTime.valueOf(jsonDateTime);
    return dt;
  }
}