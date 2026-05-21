const { ServiceBusClient } = require("@azure/service-bus");

const connectionString = process.env.SERVICE_BUS_CONNECTION_STRING;
const queueName = process.env.QUEUE_NAME || "queue.1";
const messageCount = parseInt(process.env.MESSAGE_COUNT || "20", 10);

if (!connectionString) {
  console.error("SERVICE_BUS_CONNECTION_STRING is required");
  process.exit(1);
}

async function main() {
  const client = new ServiceBusClient(connectionString);
  const sender = client.createSender(queueName);

  console.log(`[producer] Sending ${messageCount} messages to '${queueName}'...`);

  const batch = await sender.createMessageBatch();
  for (let i = 1; i <= messageCount; i++) {
    const added = batch.tryAddMessage({
      body: { id: i, task: `job-${i}`, timestamp: new Date().toISOString() },
      contentType: "application/json",
    });
    if (!added) {
      console.warn(`[producer] Batch full at message ${i} — sending early`);
      await sender.sendMessages(batch);
      batch.tryAddMessage({
        body: { id: i, task: `job-${i}`, timestamp: new Date().toISOString() },
      });
    }
  }

  await sender.sendMessages(batch);
  console.log(`[producer] Done — ${messageCount} messages enqueued`);

  await sender.close();
  await client.close();
}

main().catch((err) => {
  console.error("[producer] Fatal:", err.message);
  process.exit(1);
});
