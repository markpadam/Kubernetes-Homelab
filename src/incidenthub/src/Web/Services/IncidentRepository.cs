using Dapper;
using Microsoft.Data.SqlClient;

namespace IncidentHub.Web.Services;

public record Incident(
    int Id,
    string Title,
    string Severity,
    string Reporter,
    string Status,
    DateTime CreatedAt,
    string? AttachmentBlob);

public class IncidentRepository
{
    private readonly string _connectionString;

    public IncidentRepository(string connectionString) => _connectionString = connectionString;

    public async Task<bool> PingAsync()
    {
        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task<IEnumerable<Incident>> ListAsync()
    {
        await using var conn = new SqlConnection(_connectionString);
        return await conn.QueryAsync<Incident>(
            "SELECT Id, Title, Severity, Reporter, Status, CreatedAt, AttachmentBlob " +
            "FROM dbo.Incidents ORDER BY CreatedAt DESC");
    }

    public async Task<int> CreateAsync(string title, string severity, string reporter, string? attachmentBlob)
    {
        await using var conn = new SqlConnection(_connectionString);
        return await conn.ExecuteScalarAsync<int>(
            "INSERT INTO dbo.Incidents (Title, Severity, Reporter, Status, CreatedAt, AttachmentBlob) " +
            "OUTPUT INSERTED.Id " +
            "VALUES (@title, @severity, @reporter, 'open', SYSUTCDATETIME(), @attachmentBlob)",
            new { title, severity, reporter, attachmentBlob });
    }
}
