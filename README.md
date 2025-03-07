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
