# SQL
sp_changedbowner 'sa'
Root Cause Analysis (RCA)
Issue: Skipped Index Maintenance Job

Subject: Database Performance and Issue Resolution Summary

Dear [Recipient's Name],

Please find the summary of our recent database-related activities and issue resolutions:

DB360 Report:

The DB360 report was provided to the Application (APP) team. (Email attached.)
LRQ Configuration:

We successfully configured LRQ for both PR01 and PR02 nodes.
DPA Registration and Performance Impact:

The servers were registered in DPA. However, the APP team requested DPA to be disabled on their servers due to its impact on application performance. (Email attached.)
We implemented optimizations while keeping DPA active to ensure continued performance analysis for the APP team.
Friday – Performance Investigation:

The APP team reported slowness on their servers and requested an analysis of blocking, tempDB usage, CPU, and memory pressure.
The DBA team provided all requested details.
Saturday – Job Failures Due to Slowness:

On Saturday afternoon, L2 escalated the issue to L3 DBA, reporting job failures due to performance degradation.
L2 identified high index fragmentation in PTSDB, and further investigation revealed that the weekly maintenance job was skipping the index maintenance step.
With L3 DBA involvement, we rebuilt the indexes, which resolved the issue and allowed jobs to run smoothly.
Monday – LRQ and High Memory Usage:

The APP team requested assistance in checking LRQ.
The DBA team joined the call, provided LRQ details, and terminated LRQ sessions after confirmation from the APP team.
Most LRQ sessions had resource semaphore as the wait type. The SPLUNKD process was consuming high memory (~93%). The SA team was engaged (INC0143551701), and L2 SA escalated to L3 SA for further investigation.
PTS2_DB Performance Analysis:

Statistics were updated on [PTS2_DB].[Reporting].[tbl_live_Calc_milestone_Derived_Logic] by the DBA team, and the APP team restarted their job. However, the issue persisted.
The DBA team suggested recompiling the following views, but this was not pursued:
PTS2_DB.Reporting.Vw_Program_Milestone
PTS2_DB.Reporting.Vw_Project_Milestone
Execution plan analysis showed an excessively high estimated row count at Nested Loops (cost 51%) and Hash Match (Milestone.tb1_Project_MileStone). The DBA team recommended reviewing and optimizing the query.
Final Resolution:

The affected servers were rebooted during the APAC shift with SA team support, but the issue persisted post-reboot.
The APP team made necessary code changes, which ultimately resolved the query performance issues.
Please let us know if any further analysis or assistance is required.
