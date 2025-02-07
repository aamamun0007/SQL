Summary for App Team – SQL Query Performance Issue & Resolution
The reporting process, which runs three times daily, started experiencing slowness after January 31st. The issue was caused by a Nested Loop in the query execution plan and was recently resolved with a coding change.

Key Findings from Microsoft Engineer's Analysis:
Cause of the Issue:

The query execution plan changed after January 31st, leading to performance degradation.
The exact root cause could not be determined because there is no execution plan from before January 31st to compare with the post-issue plan.
Query Store couldn't be used because the process runs on a read-only secondary replica, and Query Store doesn’t capture data on read-only replicas (this changes in SQL 2022).
DPA couldn't store the plan because it was too large.
Investigation & Troubleshooting Steps:

Live Query Statistics: Helps track real-time query performance.
Actual Execution Plan: Captures runtime query details, including resource usage.
Extended Events for Execution Plan Capture: Allows tracking and comparison of query execution plans over time.
Challenges with Query Optimization:

The query is very large, leading to optimizer timeouts. SQL Server has a limit on the number of possible execution plans it can evaluate before choosing the best available one.
In cases like this, manual intervention (such as forcing a specific execution plan or making coding changes) may be necessary to ensure optimal performance.
Recommended Next Steps:
Monitor performance to ensure the recent coding change fully resolves the issue.
Implement execution plan tracking using Extended Events to capture future plan changes.
If further tuning is needed, the Microsoft engineer can review and provide indexing or optimization recommendations.
Let us know how you would like to proceed.






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
