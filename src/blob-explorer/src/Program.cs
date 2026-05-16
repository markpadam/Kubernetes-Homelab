using Azure.Storage.Blobs;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddRazorPages();

var connectionString = Environment.GetEnvironmentVariable("AZURE_STORAGE_CONNECTION_STRING")
    ?? throw new InvalidOperationException(
        "AZURE_STORAGE_CONNECTION_STRING is not set. " +
        "In the cluster this comes from the Kubernetes secret mounted as an env var. " +
        "Locally, set it in your terminal before running.");

var blobServiceClient = new BlobServiceClient(connectionString);
builder.Services.AddSingleton(blobServiceClient);

var app = builder.Build();

// Ensure the default container exists — same pattern you'd use against real Azure
await blobServiceClient.GetBlobContainerClient("uploads").CreateIfNotExistsAsync();

app.UseStaticFiles();
app.MapRazorPages();
app.Run();
