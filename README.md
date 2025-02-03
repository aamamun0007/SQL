# SQL
sp_changedbowner 'sa'
Root Cause Analysis (RCA)
Issue: Skipped Index Maintenance Job

Summary:
The weekly maintenance job, which consists of four steps, was executed with an incorrect starting step, causing the 'Rebuild Index' step to be skipped.

Job Steps:
Rebuild Index
Backup Database (Full)
Purge Backup History
Invoke NetBackup
Root Cause:
The job was mistakenly executed starting from Step 2 instead of Step 1, leading to the index rebuild process being skipped.
No failure notification was triggered, as the job completed successfully from Step 2 onward.
This appears to be a manual error, likely due to an on-demand full backup activity where Step 2 was intentionally used. However, the rollback to Step 1 did not occur after that activity.
Further investigation is needed to check if there was any Change (CHG) or Incident (INC) record from July/August related to this modification.
Resolution:
The job configuration has been corrected to ensure execution starts from Step 1 moving forward.
Additional security measures have been implemented:
Extra alerts for each step of the job to notify if a step is skipped.
Preventive Actions:
Implement monitoring to detect and alert on skipped steps.
Review and document any future temporary changes to job execution.
Reinforce change control processes to ensure rollback procedures are followed.
