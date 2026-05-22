using Microsoft.Data.SqlClient;

var connectionString = Environment.GetEnvironmentVariable("SQL_CONNECTION_STRING")
    ?? throw new InvalidOperationException("SQL_CONNECTION_STRING is not set.");

const string ddl = @"
IF DB_ID('incidenthub') IS NULL CREATE DATABASE incidenthub;
GO
USE incidenthub;
GO
IF OBJECT_ID('dbo.Incidents', 'U') IS NULL
CREATE TABLE dbo.Incidents (
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    Title           NVARCHAR(200) NOT NULL,
    Severity        NVARCHAR(20)  NOT NULL,
    Reporter        NVARCHAR(120) NOT NULL,
    Status          NVARCHAR(20)  NOT NULL,
    CreatedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    AttachmentBlob  NVARCHAR(400) NULL
);
";

// Retry: the SQL container can take ~30s to be ready on first apply.
for (var attempt = 1; attempt <= 20; attempt++)
{
    try
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync();
        foreach (var batch in ddl.Split("GO", StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = batch.Trim();
            if (trimmed.Length == 0) continue;
            await using var cmd = new SqlCommand(trimmed, conn);
            await cmd.ExecuteNonQueryAsync();
        }

        Console.WriteLine("[migrator] schema applied");
        return;
    }
    catch (SqlException ex) when (attempt < 20)
    {
        Console.WriteLine($"[migrator] attempt {attempt} failed: {ex.Message}");
        await Task.Delay(TimeSpan.FromSeconds(3));
    }
}

Console.Error.WriteLine("[migrator] gave up after 20 attempts");
Environment.Exit(1);
