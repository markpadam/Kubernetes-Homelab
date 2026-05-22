using Azure.Messaging.ServiceBus;
using IncidentHub.Worker;
using Microsoft.Azure.Cosmos;

var builder = Host.CreateApplicationBuilder(args);

string Required(string name) =>
    Environment.GetEnvironmentVariable(name)
        ?? throw new InvalidOperationException($"{name} is not set.");

builder.Services.AddSingleton(new ServiceBusClient(Required("SERVICEBUS_CONNECTION_STRING")));
builder.Services.AddSingleton(new CosmosClient(Required("COSMOS_CONNECTION_STRING")));
builder.Services.AddHostedService<IncidentProjectionWorker>();

var host = builder.Build();
await host.RunAsync();
