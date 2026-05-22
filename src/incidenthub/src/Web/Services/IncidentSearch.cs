using Microsoft.Azure.Cosmos;

namespace IncidentHub.Web.Services;

public record IncidentProjection(string id, int incidentId, string title, string severity, string reporter, DateTime createdAt);

public class IncidentSearch
{
    private const string DatabaseId = "incidenthub";
    private const string ContainerId = "incidents";
    private readonly Container _container;

    public IncidentSearch(CosmosClient client)
    {
        var db = client.CreateDatabaseIfNotExistsAsync(DatabaseId).GetAwaiter().GetResult();
        _container = db.Database.CreateContainerIfNotExistsAsync(ContainerId, "/severity")
            .GetAwaiter().GetResult();
    }

    public async Task<IReadOnlyList<IncidentProjection>> SearchAsync(string term)
    {
        var query = new QueryDefinition(
            "SELECT * FROM c WHERE CONTAINS(LOWER(c.title), LOWER(@term))")
            .WithParameter("@term", term);

        var iterator = _container.GetItemQueryIterator<IncidentProjection>(query);
        var results = new List<IncidentProjection>();
        while (iterator.HasMoreResults)
            results.AddRange(await iterator.ReadNextAsync());
        return results;
    }
}
