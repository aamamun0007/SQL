Subject: SSIS Job Failures – Initial Review and Follow-up Questions

Hi Sugumar,

Thank you for reporting the connection issues related to the PTS2_Reporting SSIS job on GFTPTSNADBPR02.

We’ve completed an initial review of the SQL Server and Always On Availability Group (AG) health, and here are our observations and next steps:

Initial Findings:
We did not observe any errors or failover events in the SQL Server logs around the failure timestamp (04:05 AM EST).
There were no maintenance jobs scheduled or running during the 3 AM – 6 AM window that could cause blocking or connection issues.
AG synchronization appears healthy, and the PTS2_Reporting database is hosted as the primary on Node2 as part of a separate AG from PTS2_DB and PTS2_Staging.
Request for Additional Information:
To assist with a more accurate Root Cause Analysis (RCA), could you please help provide the following details:

Job Execution Method:
How are you currently running the job? Are you using AutoSys, SQL Agent, or executing the SSIS package manually?
What steps or sequence of actions are being followed during execution?
Timeout Settings:
Does the SSIS package include long-running queries or data loads?
If yes, consider increasing timeout settings in both the SSIS connection manager and SQL command timeout properties.
SSIS Logging:
Please review SSIS logs and let us know if there are any additional error messages or stack traces that might give us more insight.
Job Dependencies:
Does this job depend on or access any other databases besides PTS2_Reporting?
Job Frequency:
How frequently is this job scheduled to run?
Network Health:
Could you please check if there were any network issues or latency between the SSIS host and SQL Server around the time of failure?
Next Steps from Our Side:
We will monitor the server closely during the 3 AM – 6 AM window over the coming days to catch any blocking, connection delays, or AG-related events.
If failures recur, we’ll collect live wait statistics, query performance data, and blocking sessions.
Based on your feedback, we may advise on connection retry logic, timeout configuration, or SSIS optimization.
Please let us know once you have this information so we can proceed with further investigation.

Best regards,
Abdullah Al Mamun
SQL Server DBA

