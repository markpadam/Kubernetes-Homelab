using System.Text.Json;
using Azure.Messaging.ServiceBus;

namespace IncidentHub.Web.Services;

public class IncidentEventPublisher
{
    private const string QueueName = "incident-created";
    private readonly ServiceBusSender _sender;

    public IncidentEventPublisher(ServiceBusClient client) =>
        _sender = client.CreateSender(QueueName);

    public Task PublishAsync(int incidentId, string title, string severity)
    {
        var body = JsonSerializer.Serialize(new { incidentId, title, severity });
        return _sender.SendMessageAsync(new ServiceBusMessage(body));
    }
}
