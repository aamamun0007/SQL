
Over the past five years at Citigroup, I have consistently demonstrated a strong commitment to operational excellence, system reliability, and collaboration across multiple teams. During this appraisal period, I have played a critical role in maintaining and optimizing the SQL Server environment that supports several high-availability and business-critical applications. I was actively involved in end-to-end database administration tasks, including performance tuning, capacity planning, backup and recovery strategies, and disaster recovery testing. I successfully led and supported several patching cycles, ensuring that all database servers remained compliant with the latest security and performance standards with minimal impact to end users. Additionally, I collaborated with infrastructure, application development, and information security teams to align on key projects, resolve cross-functional issues, and standardize configurations across production and non-production environments.

My contributions have helped reduce downtime, improve system responsiveness, and enhance overall database stability. I also mentored junior DBAs and contributed to knowledge-sharing efforts within the team, helping to build a stronger and more resilient support model. While I met or exceeded expectations on most fronts, I recognize that there is room to grow in areas such as automation and proactive process improvements. There were opportunities where earlier risk identification and more streamlined documentation could have further improved our response times and efficiency. To address this, I plan to pursue advanced training in automation tools such as PowerShell and SQL Server Agent automation techniques, and further strengthen my skills in project management and stakeholder communication.

In the upcoming months, my key priorities will include expanding automation across our maintenance and monitoring tasks, enhancing Always On Availability Group configurations for better failover handling, and continuing to drive process standardization across our environments. I will also focus on contributing to enterprise-wide initiatives aimed at improving database scalability, reliability, and security, ensuring that our data infrastructure continues to support Citigroup's business goals effectively and securely.






-------

Availability Group (AG) Naming Suggestions
1. Global Primary AG

Current AG is hosted on: GFTPTSNADBUA01 (Primary)

Suggested name:

AG_GFTPTSNADBUA_Global
or cleaner/shorter: AG_GFTPTS_Global
or by cluster role: AG_Cluster1_Global
2. Forwarder AG

Current AG2 is hosted on: GFTPTSRNADBUA1A (Primary)

Suggested name:

AG_GFTPTSRNADBUA_Forwarder
or cleaner/shorter: AG_GFTPTSR_Forwarder
or by cluster role: AG_Cluster2_Forwarder
Optional Enhancements:
You could add environment tag (e.g., PROD) or version tag (e.g., SQL15) for extra clarity:

AG_GFTPTS_Global_PROD
AG_GFTPTSR_Forwarder_PROD
Distributed AG (DAG) Naming Suggestions
Current DAG name: DistAG_CL1_CL2 (not bad, but could be more readable)

Suggested new names:

DAG_GFTPTS_GFTPTSR
DAG_Global_Forwarder
DAG_Cluster1_Cluster2
DAG_LA_TX (if tied to locations)
DAG_PROD (if only one DAG exists per env)
DAG_GFTPTS_Prod15 (if you want versioning)
Final Example Naming Set
AG (Global Primary): AG_GFTPTS_Global
AG2 (Forwarder): AG_GFTPTSR_Forwarder
Distributed AG: DAG_GFTPTS_GFTPTSR
Let me know if you'd like me to align these with any existing naming policies (like max 15 chars, always use underscores, etc.).
The key performance indicators (KPIs) for this role focus on team management, capability building, and timely delivery of technical expertise. Mentorship and career growth are essential, with a target to mentor a defined number of team members for their next position, ensuring leadership development and succession planning. Training and skill enhancement should be actively driven by conducting regular technical and process training sessions to upskill the team. Hiring as per plan must be executed efficiently, ensuring that recruitment aligns with business needs and timelines to maintain team strength and expertise. Employee engagement and satisfaction (EES) should be monitored and improved, aiming for a high engagement score to foster a motivated and productive workforce. Together, these KPIs ensure that the team is well-equipped, engaged, and aligned with business objectives, leading to efficient service delivery and continuous growth.







The key performance indicators (KPIs) for the role focus on ensuring operational excellence, customer satisfaction, and risk mitigation within the concerned technology tower (platform, database, middleware, backup, etc.). SLA adherence must be maintained at 98% or higher, ensuring that incidents and service requests are resolved within agreed timelines to minimize service disruptions. Customer escalations should be kept at zero per quarter, reflecting high service reliability and proactive issue resolution. To monitor ticket volume and resolution efficiency, the number of tickets raised should follow a stable or decreasing trend, while at least 80% of tickets should be resolved within the first response SLA to enhance operational efficiency. Client requirement adherence must be 100%, ensuring that all platform upgrades, configurations, and security measures align with business needs. Customer satisfaction (CSAT) should be maintained at a minimum of 90%, demonstrating high service quality and stakeholder confidence. Additionally, risk mitigation is crucial, with at least 90% of identified risks addressed within remediation timelines to strengthen system security, reduce downtime, and ensure compliance. Together, these KPIs provide a comprehensive framework for measuring success, improving service quality, and driving continuous improvement.









Meeting Minutes – PTS2/PTS2_Reporting: Performance Review & Discussion
Date: [Insert Date]
Attendees: [List Participants]


Subject: Change of COMP Off Plan

Hello Demonte,

I had planned to take comp off today for last week's migration activity (CHG0000109465), as we had to work the entire Saturday.

However, I had to adjust my plan since EPO had scheduled a COB test for today and tomorrow. That test has now been canceled per CISO's request for a COB freeze this weekend. The test has been rescheduled for April 12, 2025.

I will now take my comp off on Monday, March 10, 2025.

Thanks,

1. Fragmentation Email Issue
The scheduled job is running successfully; however, the email notification process is failing, which is why the report is not being received.
The team has identified the issue and is actively working on resolving the email delivery failure to ensure timely report dissemination.
2. SLTN (New Server Build) – Progress Tracking
Starting from the next meeting, SLTN will be added as a standing agenda item to track the progress of the new server build.
The Application Team will provide detailed insights into application jobs, including their schedules, types of activities (insert, delete, update), and their criticality.
3. Database Compatibility Level (130 vs. 150)
The Application Team will conduct an internal discussion regarding the compatibility level of existing databases.
Currently, SQL Server 2019 (Compatibility Level 150) is in use, but the databases are still running at Compatibility Level 130 (SQL Server 2016).
The team will assess whether an upgrade to Compatibility Level 150 is necessary and provide their recommendation.
4. Autosys Job Migration
All maintenance jobs will be migrated to Autosys to streamline and automate scheduling processes.
Next Steps:

Follow up on the email issue resolution.
Begin tracking SLTN progress in the next meeting.
Await the Application Team’s decision on database compatibility level changes.
Initiate Autosys migration for maintenance jobs.
Next Meeting Date: [Insert Date]

Let me know if you’d like any modifications!






-- 1. Retrieve MAXDOP and Cost Threshold for Parallelism
SELECT 
    (SELECT value FROM sys.configurations WHERE name = 'max degree of parallelism') AS MaxDOP,
    (SELECT value FROM sys.configurations WHERE name = 'cost threshold for parallelism') AS CostThresholdParallelism;
GO

-- 2. Retrieve Compatibility Level for all Databases
SELECT 
    name AS DatabaseName, 
    compatibility_level AS CompatibilityLevel
FROM sys.databases
ORDER BY name;
GO

-- 3. Retrieve Disk Layout and Available Free Space using xp_fixeddrives
IF OBJECT_ID('tempdb..#DiskSpace') IS NOT NULL 
    DROP TABLE #DiskSpace;

CREATE TABLE #DiskSpace (
    Drive CHAR(1),
    FreeSpace_MB INT
);

INSERT INTO #DiskSpace
EXEC xp_fixeddrives;

SELECT Drive, FreeSpace_MB 
FROM #DiskSpace
ORDER BY Drive;
GO

-- 4. Retrieve Total Disk Space and Available Free Space per Volume
-- This query uses sys.dm_os_volume_stats (available since SQL Server 2012)
SELECT DISTINCT
    vs.volume_mount_point,
    CONVERT(DECIMAL(18,2), vs.total_bytes / 1024.0 / 1024.0) AS TotalSpace_MB,
    CONVERT(DECIMAL(18,2), vs.available_bytes / 1024.0 / 1024.0) AS AvailableSpace_MB
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs;
GO

-- 5. Retrieve Memory Usage (SQL Server + OS)
SELECT 
    total_physical_memory_kb / 1024 AS TotalPhysicalMemory_MB,
    available_physical_memory_kb / 1024 AS AvailablePhysicalMemory_MB,
    total_page_file_kb / 1024 AS TotalPageFile_MB,
    available_page_file_kb / 1024 AS AvailablePageFile_MB,
    system_memory_state_desc AS MemoryState
FROM sys.dm_os_sys_memory;
GO

-- 6. Retrieve CPU Information
SELECT 
    cpu_count AS TotalCPUs, 
    scheduler_count AS SchedulerCount, 
    CASE 
        WHEN hyperthread_ratio > 0 THEN cpu_count / hyperthread_ratio 
        ELSE NULL 
    END AS PhysicalCPUs, 
    sqlserver_start_time AS SQLServerStartTime
FROM sys.dm_os_sys_info;
GO

-- 7. Retrieve Database Name, AG Name, and Listener Name (Always On Availability Groups)
IF EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states)
BEGIN
    SELECT 
        d.name AS DatabaseName, 
        ag.name AS AGName, 
        l.dns_name AS ListenerName
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.databases AS d ON drs.database_id = d.database_id
    JOIN sys.availability_groups AS ag ON drs.group_id = ag.group_id
    LEFT JOIN sys.availability_group_listeners AS l ON ag.group_id = l.group_id
    ORDER BY ag.name, d.name;
END
ELSE
BEGIN
    PRINT 'Always On Availability Groups not enabled or dm_hadr_database_replica_states not available on this server.';
END
GO

-- 8. Retrieve Total AG Nodes and Node Names (Always On Availability Groups)
IF EXISTS (SELECT 1 FROM sys.availability_groups)
BEGIN
    SELECT 
        ag.name AS AGName, 
        COUNT(ar.replica_id) AS TotalNodes,
        -- Use FOR XML PATH to concatenate replica server names (compatible with SQL Server 2012)
        STUFF(
            (
                SELECT ', ' + ar2.replica_server_name
                FROM sys.availability_replicas AS ar2
                WHERE ar2.group_id = ag.group_id
                FOR XML PATH(''), TYPE
            ).value('.', 'NVARCHAR(MAX)'),
            1, 2, ''
        ) AS NodeNames
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar ON ag.group_id = ar.group_id
    GROUP BY ag.name, ag.group_id
    ORDER BY ag.name;
END
ELSE
BEGIN
    PRINT 'Always On Availability Groups not enabled on this server.';
END
GO
