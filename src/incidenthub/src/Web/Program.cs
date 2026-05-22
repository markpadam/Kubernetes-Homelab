using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using IncidentHub.Web.Services;
using Microsoft.Azure.Cosmos;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddRazorPages();

// Connection strings are read from environment variables. In the cluster they
// arrive via Kubernetes Secrets (later stages move them to Vault Agent files).
// Locally, set them in your shell before `dotnet run`.
string Required(string name) =>
    Environment.GetEnvironmentVariable(name)
        ?? throw new InvalidOperationException($"{name} is not set.");

var sqlConnectionString = Required("SQL_CONNECTION_STRING");
var blobConnectionString = Environment.GetEnvironmentVariable("BLOB_CONNECTION_STRING");
var serviceBusConnectionString = Environment.GetEnvironmentVariable("SERVICEBUS_CONNECTION_STRING");
var cosmosConnectionString = Environment.GetEnvironmentVariable("COSMOS_CONNECTION_STRING");

builder.Services.AddSingleton(new IncidentRepository(sqlConnectionString));

if (blobConnectionString is not null)
{
    builder.Services.AddSingleton(new BlobServiceClient(blobConnectionString));
    builder.Services.AddSingleton<AttachmentStore>();
}

if (serviceBusConnectionString is not null)
{
    builder.Services.AddSingleton(new ServiceBusClient(serviceBusConnectionString));
    builder.Services.AddSingleton<IncidentEventPublisher>();
}

if (cosmosConnectionString is not null)
{
    builder.Services.AddSingleton(new CosmosClient(cosmosConnectionString));
    builder.Services.AddSingleton<IncidentSearch>();
}

var app = builder.Build();

// Health endpoints — separate liveness and readiness so probes can distinguish
// "process alive" from "process able to serve traffic".
app.MapGet("/healthz", () => Results.Ok("ok"));
app.MapGet("/ready", async (IncidentRepository repo) =>
    await repo.PingAsync() ? Results.Ok("ready") : Results.StatusCode(503));

app.UseStaticFiles();
app.MapRazorPages();
app.Run();
