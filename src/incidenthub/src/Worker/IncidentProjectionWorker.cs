using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Cosmos;

namespace IncidentHub.Worker;

public class IncidentProjectionWorker : BackgroundService
{
    private const string QueueName = "incident-created";
    private const string DatabaseId = "incidenthub";
    private const string ContainerId = "incidents";

    private readonly ServiceBusProcessor _processor;
    private readonly Container _projection;
    private readonly ILogger<IncidentProjectionWorker> _log;

    public IncidentProjectionWorker(
        ServiceBusClient sb,
        CosmosClient cosmos,
        ILogger<IncidentProjectionWorker> log)
    {
        _log = log;
        _processor = sb.CreateProcessor(QueueName);

        var db = cosmos.CreateDatabaseIfNotExistsAsync(DatabaseId).GetAwaiter().GetResult();
        _projection = db.Database.CreateContainerIfNotExistsAsync(ContainerId, "/severity")
            .GetAwaiter().GetResult();

        _processor.ProcessMessageAsync += OnMessage;
        _processor.ProcessErrorAsync += OnError;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _log.LogInformation("Worker starting — consuming from {Queue}", QueueName);
        await _processor.StartProcessingAsync(stoppingToken);

        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (TaskCanceledException) { }

        await _processor.StopProcessingAsync(CancellationToken.None);
    }

    private async Task OnMessage(ProcessMessageEventArgs args)
    {
        var body = args.Message.Body.ToString();
        _log.LogInformation("Received message: {Body}", body);

        var evt = JsonSerializer.Deserialize<IncidentEvent>(body)
            ?? throw new InvalidOperationException("Unparseable event");

        await _projection.UpsertItemAsync(new
        {
            id = evt.incidentId.ToString(),
            incidentId = evt.incidentId,
            title = evt.title,
            severity = evt.severity,
            reporter = "(projected)",
            createdAt = DateTime.UtcNow
        }, new PartitionKey(evt.severity));

        await args.CompleteMessageAsync(args.Message);
    }

    private Task OnError(ProcessErrorEventArgs args)
    {
        _log.LogError(args.Exception, "Service Bus processing error");
        return Task.CompletedTask;
    }

    private record IncidentEvent(int incidentId, string title, string severity);
}
